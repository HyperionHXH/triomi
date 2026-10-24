#include "flutter_window.h"

#include <optional>
#include <exception>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <winhttp.h>
#include <future>
#include <chrono>
#include <vector>
#include <thread>

namespace {
std::wstring ExternalWebsite(const std::string& text) {
  if (text.empty() || text.find_first_of("\r\n\t\\") != std::string::npos ||
      text.find('\0') != std::string::npos) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (!size) return {};
  std::wstring url(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), url.data(), size);
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUserNameLength =
      parts.dwPasswordLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &parts) ||
      (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS) ||
      !parts.dwHostNameLength || parts.dwUserNameLength || parts.dwPasswordLength) return {};
  return url;
}

std::string ProxyText(const wchar_t* text) {
  if (!text) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
  result.pop_back();
  return result;
}

struct SystemProxyRoute {
  flutter::EncodableMap value;
  std::string error;
};

SystemProxyRoute ResolveSystemProxy(const std::string& text) {
  const auto url = ExternalWebsite(text);
  if (url.empty()) {
    return {{}, "System proxy requires a public HTTP(S) URL"};
  }
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config{};
  if (!WinHttpGetIEProxyConfigForCurrentUser(&config)) {
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND) {
      return {{{flutter::EncodableValue("direct"), flutter::EncodableValue(true)}}, {}};
    }
    return {{}, "Cannot read Windows proxy configuration"};
  }
  std::string proxy = ProxyText(config.lpszProxy);
  std::string bypass = ProxyText(config.lpszProxyBypass);
  DWORD automatic_error = ERROR_SUCCESS;
  bool direct = proxy.empty();
  if (config.lpszAutoConfigUrl || config.fAutoDetect) {
    HINTERNET session = WinHttpOpen(L"Triomi system proxy resolver",
        WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS, 0);
    if (session) {
      WinHttpSetTimeouts(session, 2000, 2000, 2000, 2000);
      WINHTTP_AUTOPROXY_OPTIONS options{};
      if (config.lpszAutoConfigUrl) {
        options.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL;
        options.lpszAutoConfigUrl = config.lpszAutoConfigUrl;
      }
      if (config.fAutoDetect) {
        options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
        options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP |
                                    WINHTTP_AUTO_DETECT_TYPE_DNS_A;
      }
      // Never use the user's Windows credentials to fetch a PAC script.
      options.fAutoLogonIfChallenged = FALSE;
      WINHTTP_PROXY_INFO info{};
      if (WinHttpGetProxyForUrl(session, url.c_str(), &options, &info)) {
        proxy = ProxyText(info.lpszProxy);
        bypass = ProxyText(info.lpszProxyBypass);
        direct = info.dwAccessType == WINHTTP_ACCESS_TYPE_NO_PROXY;
      } else {
        automatic_error = GetLastError();
      }
      if (info.lpszProxy) GlobalFree(info.lpszProxy);
      if (info.lpszProxyBypass) GlobalFree(info.lpszProxyBypass);
      WinHttpCloseHandle(session);
    } else {
      automatic_error = GetLastError();
    }
  }
  if (config.lpszProxy) GlobalFree(config.lpszProxy);
  if (config.lpszProxyBypass) GlobalFree(config.lpszProxyBypass);
  if (config.lpszAutoConfigUrl) GlobalFree(config.lpszAutoConfigUrl);
  if (automatic_error != ERROR_SUCCESS && proxy.empty() &&
      automatic_error != ERROR_WINHTTP_AUTODETECTION_FAILED) {
    return {{}, "Windows automatic proxy resolution failed"};
  }
  return {{{flutter::EncodableValue("direct"), flutter::EncodableValue(direct)},
    {flutter::EncodableValue("proxy"), flutter::EncodableValue(proxy)},
    {flutter::EncodableValue("bypass"), flutter::EncodableValue(bypass)}}, {}};
}

constexpr UINT_PTR kProxyTimer = 0x5450;
struct PendingProxy {
  std::future<SystemProxyRoute> route;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
};
std::vector<PendingProxy> pending_proxies;
}  // namespace

#include "flutter/generated_plugin_registrant.h"
#include "windows_backup.h"
#include "app_update.h"
#include "windows_web_session.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool worker,
                             bool backup_worker)
    : project_(project), worker_(worker), backup_worker_(backup_worker) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // The backup needs only the real Dart/FFI path_provider plugin (registered by
  // Flutter's Dart registrant). Do not initialize JS, credentials or MediaKit
  // native plugins in this metadata-only process.
  if (!worker_ && !backup_worker_) RegisterPlugins(flutter_controller_->engine());
  if (!worker_ && !backup_worker_) {
    RegisterWindowsWebSession(flutter_controller_->engine()->messenger(), GetHandle());
  }
  if (!worker_) {
    platform_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        flutter_controller_->engine()->messenger(), "triomi/platform",
        &flutter::StandardMethodCodec::GetInstance());
    platform_channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          if (call.method_name() == "resolveSystemProxy") {
            const auto* args = call.arguments() == nullptr ? nullptr :
                std::get_if<flutter::EncodableMap>(call.arguments());
            const std::string* url = nullptr;
            if (args) {
              const auto entry = args->find(flutter::EncodableValue("url"));
              if (entry != args->end()) url = std::get_if<std::string>(&entry->second);
            }
            if (!url) {
              result->Error("invalid_url", "Missing system proxy URL");
              return;
            }
            auto promise = std::make_shared<std::promise<SystemProxyRoute>>();
            pending_proxies.push_back({promise->get_future(), std::move(result)});
            std::thread([promise, target = *url]() {
              try {
                promise->set_value(ResolveSystemProxy(target));
              } catch (...) {
                promise->set_exception(std::current_exception());
              }
            }).detach();
            SetTimer(GetHandle(), kProxyTimer, 15, nullptr);
            return;
          }
          if (call.method_name() == "desktopMihonStart" ||
              call.method_name() == "desktopMihonStop" ||
              call.method_name() == "desktopMihonAlive" ||
              call.method_name() == "desktopMihonTrackVerifier" ||
              call.method_name() == "desktopMihonUntrackVerifier" ||
              call.method_name() == "desktopMihonReplaceFile") {
            if (worker_ || backup_worker_) {
              result->Error("runtime_unavailable", "extension runtime is unavailable in workers");
              return;
            }
            if (call.method_name() == "desktopMihonStop") {
              mihon_runtime_.Stop();
              result->Success(flutter::EncodableValue(true));
              return;
            }
            if (call.method_name() == "desktopMihonAlive") {
              result->Success(flutter::EncodableValue(mihon_runtime_.Alive()));
              return;
            }
            const auto* args = call.arguments() == nullptr ? nullptr :
                std::get_if<flutter::EncodableMap>(call.arguments());
            if (call.method_name() == "desktopMihonTrackVerifier" ||
                call.method_name() == "desktopMihonUntrackVerifier") {
              int64_t pid = 0;
              if (args) {
                const auto entry = args->find(flutter::EncodableValue("pid"));
                if (entry != args->end()) {
                  if (const auto* value = std::get_if<int32_t>(&entry->second)) {
                    pid = *value;
                  } else if (const auto* wide_value = std::get_if<int64_t>(&entry->second)) {
                    pid = *wide_value;
                  }
                }
              }
              bool success = false;
              if (pid > 0 && pid <= static_cast<int64_t>(MAXDWORD)) {
                success = call.method_name() == "desktopMihonTrackVerifier" ?
                    mihon_runtime_.TrackVerifier(static_cast<DWORD>(pid)) :
                    mihon_runtime_.UntrackVerifier(static_cast<DWORD>(pid));
              }
              result->Success(flutter::EncodableValue(success));
              return;
            }
            if (call.method_name() == "desktopMihonReplaceFile") {
              if (!args) {
                result->Error("invalid_state_paths", "state source and destination are required");
                return;
              }
              const auto source_entry = args->find(flutter::EncodableValue("source"));
              const auto destination_entry = args->find(flutter::EncodableValue("destination"));
              const auto* source = source_entry == args->end() ? nullptr :
                  std::get_if<std::string>(&source_entry->second);
              const auto* destination = destination_entry == args->end() ? nullptr :
                  std::get_if<std::string>(&destination_entry->second);
              if (!source || !destination) {
                result->Error("invalid_state_paths", "state source and destination are required");
                return;
              }
              std::string failure_stage;
              DWORD error = ERROR_SUCCESS;
              if (!DesktopMihonRuntime::ReplaceStateFile(
                  *source, *destination, &failure_stage, &error)) {
                result->Error("state_replace_failed",
                    "could not atomically publish application runtime state: " +
                        failure_stage + " (Win32 " + std::to_string(error) + ")",
                    flutter::EncodableValue(flutter::EncodableMap{
                        {flutter::EncodableValue("stage"), flutter::EncodableValue(failure_stage)},
                        {flutter::EncodableValue("win32Error"),
                         flutter::EncodableValue(static_cast<int64_t>(error))}}));
                return;
              }
              result->Success(flutter::EncodableValue(true));
              return;
            }
            if (!args) {
              result->Error("invalid_root", "an absolute application data root is required");
              return;
            }
            const auto entry = args->find(flutter::EncodableValue("root"));
            const auto* root = entry == args->end() ? nullptr :
                std::get_if<std::string>(&entry->second);
            std::string proxy_host;
            int64_t proxy_port = 0;
            const auto host_entry = args->find(flutter::EncodableValue("proxyHost"));
            const auto port_entry = args->find(flutter::EncodableValue("proxyPort"));
            if (host_entry != args->end()) {
              const auto* host = std::get_if<std::string>(&host_entry->second);
              if (!host) {
                result->Error("invalid_proxy", "proxy host must be a string");
                return;
              }
              proxy_host = *host;
            }
            if (port_entry != args->end()) {
              if (const auto* port = std::get_if<int32_t>(&port_entry->second)) {
                proxy_port = *port;
              } else if (const auto* wide_port = std::get_if<int64_t>(&port_entry->second)) {
                proxy_port = *wide_port;
              } else {
                result->Error("invalid_proxy", "proxy port must be an integer");
                return;
              }
            }
            if ((proxy_host.empty() && proxy_port != 0) ||
                (!proxy_host.empty() && (proxy_port < 1 || proxy_port > 65535))) {
              result->Error("invalid_proxy", "proxy requires a host and port from 1 to 65535");
              return;
            }
            DWORD pid = 0;
            if (!root || !mihon_runtime_.Start(
                *root, proxy_host, static_cast<int>(proxy_port), &pid)) {
              result->Error("runtime_start_failed", "the bundled extension runtime could not start");
              return;
            }
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("pid"),
                 flutter::EncodableValue(static_cast<int64_t>(pid))}}));
            return;
          }
          if (call.method_name() == "completeLocalBackup" && backup_worker_) {
            const auto* code = call.arguments() == nullptr ? nullptr :
                std::get_if<int32_t>(call.arguments());
            if (!code || (*code != 0 && *code != 1)) {
              result->Error("invalid_exit", "backup exit code is required");
              return;
            }
            result->Success();
            // Return an observable Task Scheduler result, not Android's done
            // channel. Engine/plugin teardown follows after the message loop.
            ::PostQuitMessage(*code);
            return;
          }
          if (call.method_name() == "launchExternalUrl" && !backup_worker_) {
            const auto* args = call.arguments() == nullptr ? nullptr :
                std::get_if<flutter::EncodableMap>(call.arguments());
            if (!args) { result->Error("invalid_url", "website URL is required"); return; }
            const auto entry = args->find(flutter::EncodableValue("url"));
            const auto* text = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
            const auto url = text ? ExternalWebsite(*text) : std::wstring();
            if (url.empty()) {
              result->Error("invalid_url", "website must use HTTP(S) without credentials");
              return;
            }
            const auto launched = reinterpret_cast<INT_PTR>(ShellExecuteW(
                GetHandle(), L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
            if (launched <= 32) {
              result->Error("browser_unavailable", "Windows could not open an external browser");
            } else {
              result->Success(flutter::EncodableValue(true));
            }
            return;
          }
          if (call.method_name() == "scheduleLocalBackups" && !backup_worker_) {
            const auto* enabled = call.arguments() == nullptr ? nullptr :
                std::get_if<bool>(call.arguments());
            if (!enabled) {
              result->Error("invalid_schedule", "enabled flag is required");
              return;
            }
            const HRESULT status = SetLocalBackupSchedule(*enabled);
            if (FAILED(status)) {
              result->Error("schedule_failed",
                  "Windows Task Scheduler could not update the local backup task");
              return;
            }
            result->Success(flutter::EncodableValue(true));
            return;
          }
          if (call.method_name() == "currentAppUpdateInfo" && !backup_worker_) {
            try {
              result->Success(flutter::EncodableValue(CurrentAppUpdateInfo()));
            } catch (const std::exception&) {
              result->Error("version_unavailable", "cannot inspect running executable version");
            }
            return;
          }
          if (call.method_name() == "inspectAppUpdateInfo" && !backup_worker_) {
            const auto* args = call.arguments() == nullptr ? nullptr :
                std::get_if<flutter::EncodableMap>(call.arguments());
            if (!args) { result->Error("invalid_path", "candidate path is required"); return; }
            const auto entry = args->find(flutter::EncodableValue("path"));
            const auto* path = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
            if (!path || path->empty()) { result->Error("invalid_path", "candidate path is required"); return; }
            try {
              result->Success(flutter::EncodableValue(AppUpdateExecutableInfo(*path)));
            } catch (const std::exception&) {
              result->Error("version_unavailable", "cannot inspect candidate executable version");
            }
            return;
          }
          if (call.method_name() != "availableDiskBytes") {
            result->NotImplemented();
            return;
          }
          const auto* args = call.arguments() == nullptr ? nullptr :
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Error("invalid_path", "destination path is required"); return; }
          const auto entry = args->find(flutter::EncodableValue("path"));
          const auto* path = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
          if (!path || path->empty()) { result->Error("invalid_path", "destination path is required"); return; }
          const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
              path->data(), static_cast<int>(path->size()), nullptr, 0);
          if (!length) { result->Error("invalid_path", "destination path encoding is invalid"); return; }
          std::wstring wide(length, L'\0');
          MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(),
              static_cast<int>(path->size()), wide.data(), length);
          ULARGE_INTEGER available;
          if (!GetDiskFreeSpaceExW(wide.c_str(), &available, nullptr, nullptr)) {
            result->Error("disk_unavailable", "cannot inspect destination disk");
            return;
          }
          result->Success(flutter::EncodableValue(static_cast<int64_t>(available.QuadPart)));
        });
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow(), !backup_worker_);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!worker_ && !backup_worker_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  mihon_runtime_.Stop();
  CloseWindowsWebSessions();
  KillTimer(GetHandle(), kProxyTimer);
  pending_proxies.clear();
  platform_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_TIMER && wparam == kProxyTimer) {
    for (auto it = pending_proxies.begin(); it != pending_proxies.end();) {
      if (it->route.wait_for(std::chrono::seconds(0)) != std::future_status::ready) {
        ++it;
        continue;
      }
      try {
        const auto route = it->route.get();
        if (route.error.empty()) {
          it->result->Success(flutter::EncodableValue(route.value));
        } else {
          it->result->Error("system_proxy_failed", route.error);
        }
      } catch (...) {
        it->result->Error("system_proxy_failed", "Windows proxy resolution failed");
      }
      it = pending_proxies.erase(it);
    }
    if (pending_proxies.empty()) KillTimer(hwnd, kProxyTimer);
    return 0;
  }
  if (message == WM_SIZE) WindowsWebSessionOnResize();
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
