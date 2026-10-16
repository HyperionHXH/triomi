#include "windows_web_session.h"

#include <WebView2.h>
#include <winhttp.h>
#include <wrl.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
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
size_t privacy_generation = 0;
bool blocked = true;
bool protected_ui = false;
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
bool ParseHttps(const std::wstring& text, Url& url) {
  if (text.empty() || text.find_first_of(L"\r\n\t") != std::wstring::npos) return false;
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUserNameLength =
      parts.dwPasswordLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(text.c_str(), static_cast<DWORD>(text.size()), 0, &parts) ||
      parts.nScheme != INTERNET_SCHEME_HTTPS || !parts.dwHostNameLength ||
      parts.dwUserNameLength || parts.dwPasswordLength) return false;
  url.host.assign(parts.lpszHostName, parts.dwHostNameLength);
  std::transform(url.host.begin(), url.host.end(), url.host.begin(),
      [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  url.origin = L"https://" + url.host;
  if (parts.nPort != INTERNET_DEFAULT_HTTPS_PORT) url.origin += L":" + std::to_wstring(parts.nPort);
  return true;
}
std::wstring CanonicalPath(const std::wstring& path) {
  const DWORD size = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (!size) return {};
  std::wstring full(size, L'\0');
  const DWORD written = GetFullPathNameW(path.c_str(), size, full.data(), nullptr);
  if (!written || written >= size) return {};
  full.resize(written);
  std::transform(full.begin(), full.end(), full.begin(), [](wchar_t c) {
    return c == L'/' ? L'\\' : static_cast<wchar_t>(std::towlower(c));
  });
  while (!full.empty() && full.back() == L'\\') full.pop_back();
  return full;
}
void Failed(const SharedResult& result) {
  result->Error("browser_unavailable", "Windows source browser is unavailable");
}

struct Profile : std::enable_shared_from_this<Profile> {
  std::wstring path;
  std::wstring origin;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> web;
  ComPtr<ICoreWebView2CookieManager> cookies;
  std::vector<std::function<void(bool)>> waiting;
  bool loading = false;
  bool ready = false;
  HWND surface = nullptr;
  SharedResult pending;
  EventRegistrationToken navigation_token{};
  EventRegistrationToken popup_token{};
  EventRegistrationToken permission_token{};

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
    if (ready) { done(true); return; }
    waiting.push_back(std::move(done));
    if (loading) return;
    loading = true;
    auto self = shared_from_this();
    const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(nullptr, path.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [self](HRESULT status, ICoreWebView2Environment* environment) -> HRESULT {
          if (FAILED(status) || !environment || shutting_down) { self->Complete(false); return S_OK; }
          // Enterprise/environment overrides must never redirect this bridge
          // into a general browser store or another provider's credentials.
          ComPtr<ICoreWebView2Environment7> environment7;
          LPWSTR actual = nullptr;
          if (FAILED(environment->QueryInterface(IID_PPV_ARGS(&environment7))) ||
              FAILED(environment7->get_UserDataFolder(&actual))) {
            CoTaskMemFree(actual); self->Complete(false); return S_OK;
          }
          const bool dedicated = actual &&
              CanonicalPath(actual) == CanonicalPath(self->path);
          CoTaskMemFree(actual);
          if (!dedicated) { self->Complete(false); return S_OK; }
          self->environment = environment;
          const HRESULT creating = environment->CreateCoreWebView2Controller(owner_window,
            Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
              [self](HRESULT controller_status, ICoreWebView2Controller* controller) -> HRESULT {
                if (FAILED(controller_status) || !controller || shutting_down) {
                  self->Complete(false); return S_OK;
                }
                self->controller = controller;
                controller->put_IsVisible(FALSE);
                controller->get_CoreWebView2(&self->web);
                ComPtr<ICoreWebView2_2> web2;
                if (!self->web || FAILED(self->web.As(&web2)) ||
                    FAILED(web2->get_CookieManager(&self->cookies))) {
                  self->Complete(false); return S_OK;
                }
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
                      const bool allowed = profile && ParseHttps(raw ? raw : L"", target) && target.origin == profile->origin;
                      CoTaskMemFree(raw);
                      if (!allowed || blocked) args->put_Cancel(TRUE);
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
                if (FAILED(navigation) || FAILED(popup) || FAILED(permission)) {
                  controller->Close(); self->Complete(false); return S_OK;
                }
                self->Complete(true);
                return S_OK;
              }).Get());
          if (FAILED(creating)) self->Complete(false);
          return S_OK;
        }).Get());
    if (FAILED(started)) Complete(false);
  }
  void ReadCookies(const std::wstring& url, SharedResult result) {
    auto self = shared_from_this();
    const HRESULT status = cookies->GetCookies(url.c_str(),
      Callback<ICoreWebView2GetCookiesCompletedHandler>(
        [self, result](HRESULT status, ICoreWebView2CookieList* list) -> HRESULT {
          if (shutting_down) return S_OK;
          if (FAILED(status) || !list) { Failed(result); return S_OK; }
          UINT count = 0;
          list->get_Count(&count);
          if (count > 256) {
            result->Error("cookies_too_large", "browser cookie header exceeds request limit");
            return S_OK;
          }
          size_t bytes = 0;
          std::vector<std::pair<size_t, std::string>> values;
          for (UINT i = 0; i < count; ++i) {
            ComPtr<ICoreWebView2Cookie> cookie;
            if (FAILED(list->GetValueAtIndex(i, &cookie))) continue;
            LPWSTR name = nullptr, value = nullptr, path_value = nullptr;
            cookie->get_Name(&name);
            cookie->get_Value(&value);
            cookie->get_Path(&path_value);
            const auto key = Utf8(name), content = Utf8(value);
            const size_t path_length = path_value ? wcslen(path_value) : 0;
            CoTaskMemFree(name); CoTaskMemFree(value); CoTaskMemFree(path_value);
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
  if (blocked || shutting_down) { result->Error("locked", "application is locked"); return; }
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
  if (method == "blocked") {
    ++privacy_generation;
    blocked = Flag(*args, "blocked");
    protected_ui = Flag(*args, "protected");
    if (blocked) for (const auto& entry : profiles) entry.second->Finish(false);
    result->Success(); return;
  }
  if (method != "open" && method != "cookies" && method != "videoCookies" && method != "store") {
    result->NotImplemented(); return;
  }
  const auto url = Wide(Text(*args, "url"));
  const auto path = Wide(Text(*args, "profile"));
  Url parsed, allowed;
  if (!ParseHttps(url, parsed) || !ParseHttps(Wide(Text(*args, "origin")), allowed) ||
      parsed.origin != allowed.origin || path.empty()) {
    result->Error("invalid_url", "session requires an exact HTTPS origin"); return;
  }
  const bool video = method == "videoCookies";
  auto& slot = profiles[path];
  if (!slot) {
    slot = std::make_shared<Profile>(); slot->path = path; slot->origin = parsed.origin;
  }
  auto profile = slot;
  if (!video && profile->origin != parsed.origin) { result->Success(Value("")); return; }
  if (method != "open" && !video && !profile->Approved()) {
    if (method == "store") result->Success();
    else result->Success(Value(""));
    return;
  }
  const auto agent = Wide(Text(*args, "userAgent"));
  const auto generation = privacy_generation;
  std::shared_ptr<Map> captured;
  if (method == "store") captured = std::make_shared<Map>(*args);
  profile->Ensure([profile, method, url, parsed, agent, result, generation, captured](bool success) {
    if (shutting_down) return;
    if (!success) { Failed(result); return; }
    if (method == "open") {
      if (generation != privacy_generation) {
        result->Error("locked", "application access changed"); return;
      }
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
void WindowsWebSessionOnActivate(bool active) {
  if (!active && protected_ui) {
    ++privacy_generation;
    blocked = true;
    for (const auto& entry : profiles) entry.second->Finish(false);
  }
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
  for (const auto& entry : profiles) entry.second->Finish(false);
  profiles.clear();
  channel.reset();
  owner_window = nullptr;
}
