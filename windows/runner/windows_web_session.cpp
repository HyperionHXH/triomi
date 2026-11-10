#include "windows_web_session.h"

#include <WebView2.h>
#include <winhttp.h>
#include <shlobj.h>
#include <wrl.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cwctype>
#include <cwchar>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
using SharedResult = std::shared_ptr<Result>;
HWND owner_window = nullptr;
bool shutting_down = false;
std::unique_ptr<flutter::MethodChannel<Value>> channel;

std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), nullptr, 0);
  if (!size) return {};
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string Utf8(const wchar_t* text) {
  if (!text) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
  result.pop_back();
  return result;
}
std::string Text(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  if (it == args.end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}
bool Flag(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  return it != args.end() && std::get_if<bool>(&it->second) && std::get<bool>(it->second);
}
struct Url {
  std::wstring origin;
  std::wstring host;
};
bool ParseHttps(const std::wstring& text, Url& url, bool allow_http = false) {
  if (text.empty() || text.find_first_of(L"\r\n\t") != std::wstring::npos) return false;
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUserNameLength =
      parts.dwPasswordLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(text.c_str(), static_cast<DWORD>(text.size()), 0, &parts) ||
      (parts.nScheme != INTERNET_SCHEME_HTTPS &&
       !(allow_http && parts.nScheme == INTERNET_SCHEME_HTTP)) || !parts.dwHostNameLength ||
      parts.dwUserNameLength || parts.dwPasswordLength) return false;
  url.host.assign(parts.lpszHostName, parts.dwHostNameLength);
  std::transform(url.host.begin(), url.host.end(), url.host.begin(),
      [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  const bool https = parts.nScheme == INTERNET_SCHEME_HTTPS;
  url.origin = (https ? L"https://" : L"http://") + url.host;
  if (parts.nPort != (https ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT))
    url.origin += L":" + std::to_wstring(parts.nPort);
  return true;
}
std::wstring CanonicalPath(const std::wstring& path) {
  const DWORD size = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (!size) return {};
  std::wstring full(size, L'\0');
  const DWORD written = GetFullPathNameW(path.c_str(), size, full.data(), nullptr);
  if (!written || written >= size) return {};
  full.resize(written);
  if (full.rfind(L"\\\\?\\UNC\\", 0) == 0) full = L"\\\\" + full.substr(8);
  else if (full.rfind(L"\\\\?\\", 0) == 0) full.erase(0, 4);
  // Short aliases must compare as the same directory, never a different jar.
  const DWORD long_size = GetLongPathNameW(full.c_str(), nullptr, 0);
  if (long_size) {
    std::wstring expanded(long_size, L'\0');
    const DWORD length = GetLongPathNameW(full.c_str(), expanded.data(), long_size);
    if (length && length < long_size) { expanded.resize(length); full = std::move(expanded); }
  }
  std::transform(full.begin(), full.end(), full.begin(), [](wchar_t c) {
    return c == L'/' ? L'\\' : static_cast<wchar_t>(std::towlower(c));
  });
  while (!full.empty() && full.back() == L'\\') full.pop_back();
  return full;
}
void Failed(const SharedResult& result, const char* stage = "browser-operation", HRESULT status = E_FAIL) {
  char code[16]{};
  sprintf_s(code, "0x%08lX", static_cast<unsigned long>(status));
  result->Error("browser_unavailable", std::string("Windows browser failure at ") + stage + " (" + code + ")",
      Value(Map{{Value("stage"), Value(stage)}, {Value("hresult"), Value(code)}}));
}

// An environment owns a source's browser process group. Controllers are
// disposable operations, not owners of independently booted browser processes.
struct SourceEnvironment : std::enable_shared_from_this<SourceEnvironment> {
  std::wstring path;
  ComPtr<ICoreWebView2Environment> value;
  bool loading = false;
  const char* stage = "environment-create";
  std::vector<std::function<void(HRESULT)>> waiting;
  void Complete(HRESULT status) {
    loading = false;
    auto callbacks = std::move(waiting);
    for (auto& callback : callbacks) callback(status);
  }
  void Ensure(std::function<void(HRESULT)> done) {
    if (value) { done(S_OK); return; }
    waiting.push_back(std::move(done));
    if (loading) return;
    loading = true;
    auto self = shared_from_this();
    const int created = SHCreateDirectoryExW(nullptr, path.c_str(), nullptr);
    if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS && created != ERROR_FILE_EXISTS) {
      stage = "profile-create"; Complete(HRESULT_FROM_WIN32(created)); return;
    }
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      stage = "profile-directory"; Complete(HRESULT_FROM_WIN32(ERROR_DIRECTORY)); return;
    }
    std::wstring browser_path = path;
    const DWORD browser_attributes = GetFileAttributesW((browser_path + L"\\EBWebView").c_str());
    if (browser_attributes != INVALID_FILE_ATTRIBUTES && !(browser_attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      stage = "profile-directory"; Complete(HRESULT_FROM_WIN32(ERROR_DIRECTORY)); return;
    }
    // A real, exclusive empty probe verifies directory writes before starting
    // Edge. It never opens or replaces an existing cookie/database file.
    wchar_t probe[MAX_PATH]{};
    if (!GetTempFileNameW(browser_path.c_str(), L"twm", 0, probe)) {
      stage = "profile-writable"; Complete(HRESULT_FROM_WIN32(GetLastError())); return;
    }
    DeleteFileW(probe);
    browser_path = path.rfind(L"\\\\", 0) == 0
        ? L"\\\\?\\UNC\\" + path.substr(2) : L"\\\\?\\" + path;
    const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(nullptr, browser_path.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [self](HRESULT status, ICoreWebView2Environment* environment) -> HRESULT {
          if (shutting_down || FAILED(status) || !environment) {
            self->stage = "environment-create";
            self->Complete(FAILED(status) ? status : E_ABORT); return S_OK;
          }
          ComPtr<ICoreWebView2Environment7> environment7;
          LPWSTR actual = nullptr;
          HRESULT query = environment->QueryInterface(IID_PPV_ARGS(&environment7));
          if (SUCCEEDED(query)) query = environment7->get_UserDataFolder(&actual);
          if (FAILED(query)) {
            CoTaskMemFree(actual); self->stage = "environment-profile-query";
            self->Complete(query); return S_OK;
          }
          const bool dedicated = actual && CanonicalPath(actual) == CanonicalPath(self->path);
          CoTaskMemFree(actual);
          if (!dedicated) {
            self->stage = "environment-profile-isolation"; self->Complete(E_ACCESSDENIED); return S_OK;
          }
          self->value = environment;
          self->Complete(S_OK); return S_OK;
        }).Get());
    if (FAILED(started)) { stage = "environment-start"; Complete(started); }
  }
};
std::map<std::wstring, std::shared_ptr<SourceEnvironment>> environments;
std::shared_ptr<SourceEnvironment> EnvironmentFor(const std::wstring& path) {
  auto& entry = environments[CanonicalPath(path)];
  if (!entry) { entry = std::make_shared<SourceEnvironment>(); entry->path = CanonicalPath(path); }
  return entry;
}

struct Profile : std::enable_shared_from_this<Profile> {
  std::wstring path;
  std::wstring origin;
  std::shared_ptr<SourceEnvironment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> web;
  ComPtr<ICoreWebView2CookieManager> cookies;
  std::vector<std::function<void(bool)>> waiting;
  bool loading = false;
  bool ready = false;
  bool closed = false;
  HRESULT failure = E_FAIL;
  const char* failure_stage = "browser-initialization";
  void Reject(const char* stage, HRESULT status) {
    failure_stage = stage; failure = FAILED(status) ? status : E_UNEXPECTED;
    if (controller) controller->Close();
    controller.Reset(); web.Reset(); cookies.Reset();
    Complete(false);
  }
  HWND surface = nullptr;
  SharedResult pending;
  EventRegistrationToken navigation_token{};
  EventRegistrationToken popup_token{};
  EventRegistrationToken permission_token{};
  EventRegistrationToken process_token{};
  std::function<void()> process_failed;

  bool video_mode = false;
  bool allow_http = false;
  bool Approved() const {
    return GetFileAttributesW((path + L"/session-approved").c_str()) != INVALID_FILE_ATTRIBUTES;
  }
  void Finish(bool saved) {
    if (!surface && !pending) return;
    if (web) web->Stop();
    if (controller) {
      controller->put_IsVisible(FALSE);
      controller->Close();
    }
    // Closing is not merely hiding: destroy the page's script/network runtime.
    controller.Reset();
    web.Reset();
    cookies.Reset();
    ready = false;
    const HWND old = surface;
    surface = nullptr;
    if (old) DestroyWindow(old);
    auto result = std::move(pending);
    if (result) result->Success(Value(Map{{Value("saved"), Value(saved)}}));
    if (owner_window && !shutting_down) SetFocus(owner_window);
  }
  void Complete(bool success) {
    loading = false;
    ready = success;
    auto callbacks = std::move(waiting);
    for (auto& callback : callbacks) callback(success);
  }
  void Ensure(std::function<void(bool)> done) {
    if (ready && environment && environment->value) { done(true); return; }
    waiting.push_back(std::move(done));
    if (loading) return;
    loading = true;
    if (controller) controller->Close();
    controller.Reset(); web.Reset(); cookies.Reset(); ready = false;
    auto self = shared_from_this();
    environment = EnvironmentFor(path);
    environment->Ensure([self](HRESULT status) {
          if (self->closed || shutting_down) { self->Reject("controller-cancelled", E_ABORT); return; }
          if (FAILED(status)) { self->Reject(self->environment->stage, status); return; }
          const HRESULT creating = self->environment->value->CreateCoreWebView2Controller(owner_window,
            Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
              [self](HRESULT controller_status, ICoreWebView2Controller* controller) -> HRESULT {
                if (FAILED(controller_status) || !controller || shutting_down || self->closed) {
                  if (controller) controller->Close();
                  self->Reject("controller-create", FAILED(controller_status) ? controller_status : E_ABORT); return S_OK;
                }
                self->controller = controller;
                controller->put_IsVisible(FALSE);
                HRESULT setup = controller->get_CoreWebView2(&self->web);
                ComPtr<ICoreWebView2_2> web2;
                if (SUCCEEDED(setup)) setup = self->web ? self->web.As(&web2) : E_POINTER;
                if (SUCCEEDED(setup)) setup = web2->get_CookieManager(&self->cookies);
                if (FAILED(setup)) { self->Reject("controller-cookie-manager", setup); return S_OK; }
                ComPtr<ICoreWebView2Settings> settings;
                self->web->get_Settings(&settings);
                if (settings) {
                  settings->put_AreDevToolsEnabled(FALSE);
                  settings->put_AreDefaultContextMenusEnabled(FALSE);
                  settings->put_IsStatusBarEnabled(FALSE);
                }
                // Browser-default TLS verification is deliberately untouched.
                const HRESULT navigation = self->web->add_NavigationStarting(
                  Callback<ICoreWebView2NavigationStartingEventHandler>(
                    [weak = std::weak_ptr<Profile>(self)](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
                      auto profile = weak.lock();
                      LPWSTR raw = nullptr;
                      args->get_Uri(&raw);
                      Url target;
                      const bool allowed = profile && ParseHttps(raw ? raw : L"", target, profile->allow_http) &&
                          (profile->video_mode || target.origin == profile->origin);
                      CoTaskMemFree(raw);
                      if (!allowed) args->put_Cancel(TRUE);
                      return S_OK;
                    }).Get(), &self->navigation_token);
                const HRESULT popup = self->web->add_NewWindowRequested(
                  Callback<ICoreWebView2NewWindowRequestedEventHandler>(
                    [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                      args->put_Handled(TRUE); return S_OK;
                    }).Get(), &self->popup_token);
                const HRESULT permission = self->web->add_PermissionRequested(
                  Callback<ICoreWebView2PermissionRequestedEventHandler>(
                    [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
                      args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY); return S_OK;
                    }).Get(), &self->permission_token);
                const HRESULT process = self->web->add_ProcessFailed(
                  Callback<ICoreWebView2ProcessFailedEventHandler>(
                    [weak = std::weak_ptr<Profile>(self)](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
                      const auto profile = weak.lock();
                      if (!profile || profile->closed || shutting_down) return S_OK;
                      COREWEBVIEW2_PROCESS_FAILED_KIND kind;
                      if (FAILED(args->get_ProcessFailedKind(&kind))) return S_OK;
                      if (kind != COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED &&
                          kind != COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED) return S_OK;
                      profile->ready = false;
                      if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED)
                        profile->environment->value.Reset();
                      if (profile->process_failed) profile->process_failed();
                      return S_OK;
                    }).Get(), &self->process_token);
                if (FAILED(navigation) || FAILED(popup) || FAILED(permission) || FAILED(process)) {
                  self->Reject("controller-policy", FAILED(navigation) ? navigation : FAILED(popup) ? popup : FAILED(permission) ? permission : process); return S_OK;
                }
                self->Complete(true);
                return S_OK;
              }).Get());
          if (FAILED(creating)) self->Reject("controller-start", creating);
        });
  }
  void ReadCookies(const std::wstring& url, SharedResult result) {
    auto self = shared_from_this();
    const HRESULT status = cookies->GetCookies(url.c_str(),
      Callback<ICoreWebView2GetCookiesCompletedHandler>(
        [self, result, url](HRESULT status, ICoreWebView2CookieList* list) -> HRESULT {
          if (shutting_down) return S_OK;
          if (FAILED(status) || !list) { Failed(result, "cookies-read", FAILED(status) ? status : E_POINTER); return S_OK; }
          UINT count = 0;
          list->get_Count(&count);
          if (count > 256) {
            result->Error("cookies_too_large", "browser cookie header exceeds request limit");
            return S_OK;
          }
          Url target;
          URL_COMPONENTS parts{}; parts.dwStructSize = sizeof(parts);
          parts.dwUrlPathLength = static_cast<DWORD>(-1);
          if (!ParseHttps(url, target) || !WinHttpCrackUrl(url.c_str(),
              static_cast<DWORD>(url.size()), 0, &parts)) { Failed(result, "cookies-url", E_INVALIDARG); return S_OK; }
          const std::wstring request_path = parts.dwUrlPathLength
              ? std::wstring(parts.lpszUrlPath, parts.dwUrlPathLength) : L"/";
          size_t bytes = 0;
          std::vector<std::pair<size_t, std::string>> values;
          for (UINT i = 0; i < count; ++i) {
            ComPtr<ICoreWebView2Cookie> cookie;
            if (FAILED(list->GetValueAtIndex(i, &cookie))) continue;
            LPWSTR name = nullptr, value = nullptr, path_value = nullptr, domain_value = nullptr;
            const bool metadata = SUCCEEDED(cookie->get_Name(&name)) && SUCCEEDED(cookie->get_Value(&value)) &&
                SUCCEEDED(cookie->get_Path(&path_value)) && SUCCEEDED(cookie->get_Domain(&domain_value));
            const auto key = Utf8(name), content = Utf8(value);
            std::wstring domain = domain_value ? domain_value : L"";
            const std::wstring cookie_path = path_value && *path_value ? path_value : L"/";
            const size_t path_length = cookie_path.size();
            CoTaskMemFree(name); CoTaskMemFree(value); CoTaskMemFree(path_value); CoTaskMemFree(domain_value);
            if (!metadata || domain.empty() || cookie_path.front() != L'/') continue;
            std::transform(domain.begin(), domain.end(), domain.begin(),
                [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
            const bool domain_cookie = !domain.empty() && domain[0] == L'.';
            if (domain_cookie) domain.erase(0, 1);
            const bool host_match = domain == target.host || (domain_cookie &&
                target.host.size() > domain.size() &&
                target.host.compare(target.host.size() - domain.size(), domain.size(), domain) == 0 &&
                target.host[target.host.size() - domain.size() - 1] == L'.');
            const bool path_match = request_path == cookie_path ||
                (request_path.size() > cookie_path.size() &&
                 request_path.compare(0, cookie_path.size(), cookie_path) == 0 &&
                 (cookie_path.back() == L'/' || request_path[cookie_path.size()] == L'/'));
            BOOL secure = FALSE, session_cookie = TRUE;
            double expires = 0;
            if (FAILED(cookie->get_IsSecure(&secure)) || FAILED(cookie->get_IsSession(&session_cookie)) ||
                FAILED(cookie->get_Expires(&expires))) continue;
            const double now = std::chrono::duration<double>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            if (!host_match || !path_match || (secure && url.find(L"https://") != 0) ||
                (!session_cookie && expires <= now)) continue;
            bytes += key.size() + content.size() + 3;
            if (bytes > 32768) {
              result->Error("cookies_too_large", "browser cookie header exceeds request limit");
              return S_OK;
            }
            if (!key.empty() && key.find_first_of(";=\r\n") == std::string::npos &&
                content.find_first_of(";\r\n") == std::string::npos) {
              values.emplace_back(path_length, key + "=" + content);
            }
          }
          std::stable_sort(values.begin(), values.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
          std::string header;
          for (const auto& value : values) {
            if (!header.empty()) header += "; ";
            header += value.second;
          }
          result->Success(Value(header));
          return S_OK;
        }).Get());
    if (FAILED(status)) Failed(result);
  }
  ~Profile() {
    if (controller) controller->Close();
  }
};
std::map<std::wstring, std::shared_ptr<Profile>> profiles;

struct VideoSession {
  int64_t id = 0;
  std::shared_ptr<Profile> profile;
  bool active = true;
  bool entered = false;
  std::wstring target;
  UINT64 navigation_id = 0;
  void Close() {
    active = false;
    profile->closed = true;
    if (profile->web) profile->web->Stop();
    if (profile->controller) profile->controller->Close();
    profile->cookies.Reset(); profile->web.Reset(); profile->controller.Reset();
    profile->ready = false;
  }
  void Error(const char* message) {
    if (active && channel) channel->InvokeMethod("videoMessage", std::make_unique<Value>(Map{
      {Value("id"), Value(id)}, {Value("error"), Value(message)}}));
  }
};
std::map<int64_t, std::shared_ptr<VideoSession>> videos;
int64_t VideoId(const Map& args) {
  const auto found = args.find(Value("id"));
  if (found == args.end()) return 0;
  if (const auto* id = std::get_if<int32_t>(&found->second)) return *id;
  if (const auto* id = std::get_if<int64_t>(&found->second)) return *id;
  return 0;
}
std::wstring JavascriptString(const std::wstring& value) {
  std::wstring escaped = L"\"";
  for (const auto c : value) {
    if (c == L'"' || c == L'\\') escaped += L'\\';
    if (c < 32 || c == 0x2028 || c == 0x2029) {
      wchar_t hex[7]; swprintf_s(hex, L"\\u%04x", static_cast<unsigned>(c)); escaped += hex;
    } else escaped += c;
  }
  return escaped + L"\"";
}
bool SourceProfilePath(const std::wstring& raw) {
  const auto path = CanonicalPath(raw);
  const auto separator = path.find_last_of(L'\\');
  if (separator == std::wstring::npos || path.size() - separator - 1 != 64) return false;
  const auto parent = path.substr(0, separator);
  const std::wstring suffix = L"\\windows-source-sessions";
  if (parent.size() < suffix.size() || parent.compare(parent.size() - suffix.size(), suffix.size(), suffix) != 0) return false;
  for (size_t i = separator + 1; i < path.size(); ++i)
    if (!((path[i] >= L'0' && path[i] <= L'9') || (path[i] >= L'a' && path[i] <= L'f'))) return false;
  auto component = path;
  while (component.size() > 3) {
    const DWORD attributes = GetFileAttributesW(component.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    const auto slash = component.find_last_of(L'\\');
    if (slash == std::wstring::npos) break;
    component.resize(slash);
  }
  return true;
}
void StartVideo(const Map& args, SharedResult result) {
  const auto id = VideoId(args);
  const auto path = Wide(Text(args, "profile")), target = Wide(Text(args, "url"));
  const auto script = Wide(Text(args, "script")), agent = Wide(Text(args, "userAgent"));
  const auto referer = Wide(Text(args, "referer"));
  Url source, destination, parent;
  if (id <= 0 || videos.count(id) || !SourceProfilePath(path) ||
      !ParseHttps(Wide(Text(args, "origin")), source, true) || !ParseHttps(target, destination, true) ||
      script.empty() || agent.empty() || agent.find_first_of(L"\r\n") != std::wstring::npos ||
      (!referer.empty() && !ParseHttps(referer, parent, destination.origin.find(L"http://") == 0))) {
    result->Error("invalid_video", "invalid source video context"); return;
  }
  // A controller per operation; never close or navigate the user's login UI.
  auto video = std::make_shared<VideoSession>(); video->id = id; video->target = target;
  video->profile = std::make_shared<Profile>(); video->profile->path = path;
  video->profile->origin = source.origin; video->profile->video_mode = true;
  video->profile->allow_http = destination.origin.find(L"http://") == 0;
  video->profile->process_failed = [weak = std::weak_ptr<VideoSession>(video)] {
    if (const auto session = weak.lock()) session->Error("Windows browser process exited during video resolution; retry to reopen the source browser");
  };
  videos[id] = video;
  video->profile->Ensure([video, result, target, script, agent, referer](bool success) {
    if (shutting_down) { video->Close(); return; }
    if (!video->active) { video->Close(); result->Success(); return; }
    if (!success) { Failed(result, video->profile->failure_stage, video->profile->failure); return; }
    auto profile = video->profile;
    RECT bounds{0, 0, 1280, 720}; profile->controller->put_Bounds(bounds);
    ComPtr<ICoreWebView2Settings> settings; ComPtr<ICoreWebView2Settings2> settings2;
    HRESULT settings_status = profile->web->get_Settings(&settings);
    if (SUCCEEDED(settings_status)) settings_status = settings ? settings.As(&settings2) : E_POINTER;
    if (SUCCEEDED(settings_status)) settings_status = settings2->put_UserAgent(agent.c_str());
    if (FAILED(settings_status)) { Failed(result, "video-user-agent", settings_status); return; }
    EventRegistrationToken message_token{}, starting_token{}, navigation_token{};
    const auto weak = std::weak_ptr<VideoSession>(video);
    const HRESULT messages = profile->web->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
          const auto session = weak.lock();
          if (!session || !session->active || !channel) return S_OK;
          LPWSTR json = nullptr;
          if (FAILED(args->get_WebMessageAsJson(&json))) return S_OK;
          const auto message = Utf8(json); CoTaskMemFree(json);
          if (message.size() > 131072) return S_OK;
          channel->InvokeMethod("videoMessage", std::make_unique<Value>(Map{
            {Value("id"), Value(session->id)}, {Value("message"), Value(message)}}));
          return S_OK;
        }).Get(), &message_token);
    const HRESULT starting = profile->web->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
          if (const auto session = weak.lock()) {
            args->get_NavigationId(&session->navigation_id);
          }
          return S_OK;
        }).Get(), &starting_token);
    const HRESULT navigation = profile->web->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
        [weak, has_referer = !referer.empty()](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
          const auto session = weak.lock(); BOOL success = FALSE; args->get_IsSuccess(&success);
          COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
          args->get_WebErrorStatus(&status);
          UINT64 navigation_id = 0;
          args->get_NavigationId(&navigation_id);
          // A page may start another navigation before the old request reports
          // its reset/abort. Only the current document owns resolver failure.
          if (!session || !session->active || navigation_id != session->navigation_id) return S_OK;
          if (success && has_referer && !session->entered) {
            // Let the entry document finish its own redirects before creating
            // one user-like link navigation. DOMContentLoaded can race a site's
            // location.replace/meta-refresh and reset the actual playback page.
            session->entered = true;
            LPWSTR current = nullptr;
            sender->get_Source(&current);
            const bool at_target = current && std::wstring(current) == session->target;
            CoTaskMemFree(current);
            if (!at_target) {
              session->navigation_id = 0;
              const auto link = L"(() => { const a=document.createElement('a'); a.href=" +
                  JavascriptString(session->target) + L";a.target='_self';document.body.appendChild(a);a.click(); })();";
              const HRESULT started = sender->ExecuteScript(link.c_str(), nullptr);
              if (FAILED(started)) session->Error("Windows browser failed to enter the playback page");
            }
          }
          if (session && !success && status != COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) {
            const auto phase = has_referer && !session->entered ? "source-entry" : "playback-page";
            ComPtr<ICoreWebView2NavigationCompletedEventArgs2> response;
            int http_status = 0;
            if (SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(&response))))
              response->get_HttpStatusCode(&http_status);
            const auto message = Utf8(L"\u64ad\u653e\u9875\u52a0\u8f7d\u5931\u8d25") +
                " (WebView2 " + phase + " navigation status " + std::to_string(static_cast<int>(status)) +
                (http_status > 0 ? ", HTTP " + std::to_string(http_status) : "") + ")";
            session->Error(message.c_str());
          }
          return S_OK;
        }).Get(), &navigation_token);
    if (FAILED(messages) || FAILED(starting) || FAILED(navigation)) { Failed(result, "video-events", FAILED(messages) ? messages : FAILED(starting) ? starting : navigation); return; }
    const HRESULT injected = profile->web->AddScriptToExecuteOnDocumentCreated(script.c_str(),
      Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
        [video, result, target, referer](HRESULT status, LPCWSTR) -> HRESULT {
          if (shutting_down) { video->Close(); return S_OK; }
          if (!video->active) { video->Close(); result->Success(); return S_OK; }
          if (FAILED(status)) { Failed(result, "video-script", status); return S_OK; }
          const HRESULT navigation = video->profile->web->Navigate((referer.empty() ? target : referer).c_str());
          if (FAILED(navigation)) { Failed(result, "video-navigate", navigation); return S_OK; }
          result->Success(); return S_OK;
        }).Get());
    if (FAILED(injected)) Failed(result, "video-script-start", injected);
  });
}

LRESULT CALLBACK BrowserProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* profile = reinterpret_cast<Profile*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    profile = static_cast<Profile*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(profile));
  }
  if (profile) {
    if (message == WM_SIZE && profile->controller) {
      RECT rect{}; GetClientRect(window, &rect); rect.top = 44;
      profile->controller->put_Bounds(rect);
      return 0;
    }
    if (message == WM_COMMAND) {
      if (LOWORD(wparam) == 1) {
        // Approval is a device-local noncredential marker. Browser cookies are
        // persisted only by WebView2, never copied into app preferences/backup.
        HANDLE marker = CreateFileW((profile->path + L"/session-approved").c_str(),
          GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (marker != INVALID_HANDLE_VALUE) {
          CloseHandle(marker); profile->Finish(true);
        }
      } else if (LOWORD(wparam) == 2) {
        profile->Finish(false);
      } else if (LOWORD(wparam) == 3 && profile->web) {
        profile->web->Reload();
      }
      return 0;
    }
    if (message == WM_CLOSE) { profile->Finish(false); return 0; }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
void OpenBrowser(const std::shared_ptr<Profile>& profile, const std::wstring& url,
    const std::wstring& agent, SharedResult result) {
  if (shutting_down) { result->Error("closed", "application is closing"); return; }
  for (const auto& entry : profiles) {
    if (entry.second->pending) { result->Error("session_busy", "a source browser is already open"); return; }
  }
  WNDCLASSW klass{};
  klass.lpfnWndProc = BrowserProc;
  klass.hInstance = GetModuleHandleW(nullptr);
  klass.lpszClassName = L"TriomiSourceSession";
  klass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&klass);
  RECT rect{}; GetClientRect(owner_window, &rect);
  profile->surface = CreateWindowExW(0, klass.lpszClassName, L"\u6765\u6e90\u7ad9\u70b9\u9a8c\u8bc1",
    WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0, rect.right, rect.bottom,
    owner_window, nullptr, klass.hInstance, profile.get());
  if (!profile->surface) { Failed(result); return; }
  profile->pending = std::move(result);
  CreateWindowW(L"BUTTON", L"\u4fdd\u5b58\u4f1a\u8bdd\u5e76\u5173\u95ed", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
    8, 6, 170, 32, profile->surface, reinterpret_cast<HMENU>(1), klass.hInstance, nullptr);
  CreateWindowW(L"BUTTON", L"\u53d6\u6d88\u5e76\u5173\u95ed", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
    188, 6, 130, 32, profile->surface, reinterpret_cast<HMENU>(2), klass.hInstance, nullptr);
  CreateWindowW(L"BUTTON", L"\u5237\u65b0", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
    328, 6, 90, 32, profile->surface, reinterpret_cast<HMENU>(3), klass.hInstance, nullptr);
  CreateWindowW(L"STATIC", profile->origin.c_str(), WS_CHILD | WS_VISIBLE,
    430, 13, (std::max)(100L, rect.right - 440), 24, profile->surface, nullptr, klass.hInstance, nullptr);
  profile->controller->put_ParentWindow(profile->surface);
  rect.top = 44;
  profile->controller->put_Bounds(rect);
  ComPtr<ICoreWebView2Settings> settings;
  profile->web->get_Settings(&settings);
  ComPtr<ICoreWebView2Settings2> settings2;
  if (settings && SUCCEEDED(settings.As(&settings2)) && !agent.empty()) settings2->put_UserAgent(agent.c_str());
  SetWindowPos(profile->surface, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  profile->controller->put_IsVisible(TRUE);
  profile->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
  if (FAILED(profile->web->Navigate(url.c_str()))) profile->Finish(false);
}
void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> raw_result) {
  SharedResult result(std::move(raw_result));
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!args) { result->Error("invalid_args", "session arguments required"); return; }
  const auto& method = call.method_name();
  if (method == "startVideo") { StartVideo(*args, result); return; }
  if (method == "closeVideo") {
    const auto found = videos.find(VideoId(*args));
    if (found != videos.end()) { found->second->Close(); videos.erase(found); }
    result->Success(); return;
  }
  if (method == "clearHttpCache") {
    const auto path = Wide(Text(*args, "profile"));
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (path.empty() || attributes == INVALID_FILE_ATTRIBUTES ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
      result->Error("invalid_profile", "cache cleanup requires an existing owned profile"); return;
    }
    auto profile = std::make_shared<Profile>();
    profile->path = path;
    // A temporary hidden controller performs no navigation and never mutates
    // Cookies, DOM storage, sessions, downloads or browser history.
    profile->Ensure([profile, result](bool success) {
      ComPtr<ICoreWebView2_13> web13;
      ComPtr<ICoreWebView2Profile> base;
      ComPtr<ICoreWebView2Profile2> storage;
      if (!success || !profile->web || FAILED(profile->web.As(&web13)) ||
          FAILED(web13->get_Profile(&base)) || FAILED(base.As(&storage))) {
        if (profile->controller) profile->controller->Close();
        Failed(result); return;
      }
      const HRESULT started = storage->ClearBrowsingData(COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE,
        Callback<ICoreWebView2ClearBrowsingDataCompletedHandler>(
          [profile, result](HRESULT status) -> HRESULT {
            // Keep the controller alive until completion; closing early cancels
            // the API without necessarily delivering its completion callback.
            if (profile->controller) profile->controller->Close();
            if (!shutting_down) result->Success(Value(SUCCEEDED(status)));
            return S_OK;
          }).Get());
      if (FAILED(started)) {
        if (profile->controller) profile->controller->Close();
        Failed(result);
      }
    });
    return;
  }
  if (method != "open" && method != "cookies" && method != "videoCookies" && method != "store") {
    result->NotImplemented(); return;
  }
  const auto url = Wide(Text(*args, "url"));
  const auto path = Wide(Text(*args, "profile"));
  const bool video = method == "videoCookies";
  Url parsed, allowed;
  if (!ParseHttps(url, parsed) || !ParseHttps(Wide(Text(*args, "origin")), allowed) ||
      (!video && parsed.origin != allowed.origin) || !SourceProfilePath(path)) {
    result->Error("invalid_url", "session requires an owned source HTTPS profile"); return;
  }
  auto& slot = profiles[path];
  if (!slot) {
    slot = std::make_shared<Profile>(); slot->path = path; slot->origin = allowed.origin;
  }
  auto profile = slot;
  if (profile->origin != allowed.origin) { result->Success(Value("")); return; }
  if (method != "open" && !video && !profile->Approved()) {
    if (method == "store") result->Success();
    else result->Success(Value(""));
    return;
  }
  const auto agent = Wide(Text(*args, "userAgent"));
  std::shared_ptr<Map> captured;
  if (method == "store") captured = std::make_shared<Map>(*args);
  profile->Ensure([profile, method, url, parsed, agent, result, captured](bool success) {
    if (shutting_down) return;
    if (!success) { Failed(result, profile->failure_stage, profile->failure); return; }
    if (method == "open") {
      OpenBrowser(profile, url, agent, result); return;
    }
    if (method == "store") {
      const auto it = captured->find(Value("cookies"));
      const auto* values = it == captured->end() ? nullptr : std::get_if<flutter::EncodableList>(&it->second);
      if (!values || values->size() > 256) {
        result->Error("invalid_cookies", "cookie response exceeds request limit"); return;
      }
      for (const auto& value : *values) {
        const auto* item = std::get_if<Map>(&value);
        if (!item) continue;
        const auto name = Wide(Text(*item, "name")), content = Wide(Text(*item, "value"));
        auto domain = Wide(Text(*item, "domain"));
        const auto cookie_path = Wide(Text(*item, "path"));
        std::wstring bare_domain = domain;
        if (!bare_domain.empty() && bare_domain[0] == L'.') bare_domain.erase(0, 1);
        std::transform(bare_domain.begin(), bare_domain.end(), bare_domain.begin(),
            [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        const bool same_host = parsed.host == bare_domain;
        const bool parent_domain = parsed.host.size() > bare_domain.size() &&
            parsed.host.compare(parsed.host.size() - bare_domain.size(), bare_domain.size(), bare_domain) == 0 &&
            parsed.host[parsed.host.size() - bare_domain.size() - 1] == L'.';
        if ((!same_host && !parent_domain) || bare_domain.empty() || name.empty() ||
            name.size() + content.size() > 32768 || name.find_first_of(L";=\r\n") != std::wstring::npos ||
            content.find_first_of(L";\r\n") != std::wstring::npos || cookie_path.empty() || cookie_path[0] != L'/') continue;
        ComPtr<ICoreWebView2Cookie> cookie;
        if (FAILED(profile->cookies->CreateCookie(name.c_str(), content.c_str(), domain.c_str(), cookie_path.c_str(), &cookie))) continue;
        cookie->put_IsSecure(Flag(*item, "secure"));
        cookie->put_IsHttpOnly(Flag(*item, "httpOnly"));
        const auto expiry = item->find(Value("expires"));
        if (expiry != item->end()) {
          if (const auto* seconds = std::get_if<double>(&expiry->second)) {
            const double now = std::chrono::duration<double>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            if (*seconds <= now) {
              profile->cookies->DeleteCookie(cookie.Get());
              continue;
            }
            cookie->put_Expires(*seconds);
          }
        }
        if (FAILED(profile->cookies->AddOrUpdateCookie(cookie.Get()))) {
          result->Error("cookie_rejected", "browser rejected a response cookie"); return;
        }
      }
      result->Success(); return;
    }
    profile->ReadCookies(url, result);
  });
}
}  // namespace

void RegisterWindowsWebSession(flutter::BinaryMessenger* messenger, HWND owner) {
  owner_window = owner;
  shutting_down = false;
  channel = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "triomi/windows-web-session", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(Handle);
}
void WindowsWebSessionOnResize() {
  if (!owner_window) return;
  RECT rect{};
  GetClientRect(owner_window, &rect);
  for (const auto& entry : profiles) {
    if (entry.second->surface) {
      SetWindowPos(entry.second->surface, HWND_TOP, 0, 0, rect.right, rect.bottom,
          SWP_NOACTIVATE);
    }
  }
}
void CloseWindowsWebSessions() {
  shutting_down = true;
  for (const auto& entry : videos) entry.second->Close();
  videos.clear();
  for (const auto& entry : profiles) entry.second->Finish(false);
  profiles.clear();
  environments.clear();
  channel.reset();
  owner_window = nullptr;
}
