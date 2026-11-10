#include "windows_content_updates.h"

#include <netlistmgr.h>
#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <taskschd.h>
#include <wrl/client.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cwchar>
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kNotificationId = 0x5443;
constexpr UINT kNotificationMessage = WM_APP + 0x643;
constexpr UINT kNotificationPumpMessage = WM_APP + 0x644;
constexpr size_t kMaximumNotifications = 32;
HWND owner = nullptr;
bool icon_added = false;
bool manga_running = false;
std::unique_ptr<flutter::MethodChannel<Value>> manga_channel;
std::unique_ptr<flutter::MethodChannel<Value>> notification_channel;
struct PendingNotification {
  UINT id;
  std::wstring title;
  std::wstring body;
  std::unique_ptr<flutter::MethodResult<Value>> result;
  bool shown = false;
};
std::deque<PendingNotification> notifications;
UINT next_notification_id = kNotificationId;
UINT_PTR notification_timer = 0;

class Bstr {
 public:
  explicit Bstr(const wchar_t* text) : value_(SysAllocString(text)) {}
  ~Bstr() { SysFreeString(value_); }
  operator BSTR() const { return value_; }
 private:
  BSTR value_;
};
#define CHECK_HR(expression) \
  do { const HRESULT hr = (expression); if (FAILED(hr)) return hr; } while (false)

const Map* Arguments(const flutter::MethodCall<Value>& call) {
  return call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
}
bool Flag(const Map* args, const char* key, bool fallback = false) {
  if (!args) return fallback;
  const auto entry = args->find(Value(key));
  if (entry == args->end()) return fallback;
  const auto value = std::get_if<bool>(&entry->second);
  return value ? *value : fallback;
}
std::string Text(const Map* args, const char* key) {
  if (!args) return {};
  const auto entry = args->find(Value(key));
  if (entry == args->end()) return {};
  const auto value = std::get_if<std::string>(&entry->second);
  return value ? *value : std::string();
}
// Bound UTF-16 text, drop controls, and never interpolate paths/headers/URLs.
std::wstring NotificationText(const std::string& text, size_t maximum) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(std::min<size_t>(text.size(), 8192)), nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(std::min<size_t>(text.size(), 8192)), result.data(), length);
  for (auto& ch : result) if (ch < 32 || ch == 127) ch = L' ';
  if (result.size() > maximum) result.resize(maximum);
  if (!result.empty() && result.back() >= 0xd800 && result.back() <= 0xdbff) {
    result.pop_back();
  }
  return result;
}
HRESULT UserSid(std::wstring* sid) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> bytes(size);
  const bool ok = GetTokenInformation(token, TokenUser, bytes.data(), size, &size) != FALSE;
  const DWORD error = ok ? ERROR_SUCCESS : GetLastError();
  CloseHandle(token);
  if (!ok) return HRESULT_FROM_WIN32(error);
  LPWSTR value = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid, &value)) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  *sid = value;
  LocalFree(value);
  return S_OK;
}
HRESULT TaskFolder(ComPtr<ITaskService>* service, ComPtr<ITaskFolder>* folder,
                   std::wstring* name, std::wstring* sid) {
  CHECK_HR(UserSid(sid));
  *name = L"TriomiContentUpdates-" + *sid;
  CHECK_HR(CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(service->GetAddressOf())));
  VARIANT empty;
  VariantInit(&empty);
  CHECK_HR((*service)->Connect(empty, empty, empty, empty));
  return (*service)->GetFolder(Bstr(L"\\"), folder->GetAddressOf());
}
bool MissingTask(HRESULT hr) {
  return hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
         hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND);
}
HRESULT Scheduled(bool* enabled) {
  *enabled = false;
  ComPtr<ITaskService> service;
  ComPtr<ITaskFolder> folder;
  std::wstring name, sid;
  CHECK_HR(TaskFolder(&service, &folder, &name, &sid));
  ComPtr<IRegisteredTask> task;
  const HRESULT found = folder->GetTask(Bstr(name.c_str()), task.GetAddressOf());
  if (MissingTask(found)) return S_OK;
  CHECK_HR(found);
  VARIANT_BOOL active = VARIANT_FALSE;
  CHECK_HR(task->get_Enabled(&active));
  TASK_STATE state = TASK_STATE_UNKNOWN;
  CHECK_HR(task->get_State(&state));
  *enabled = active == VARIANT_TRUE && state != TASK_STATE_DISABLED &&
             state != TASK_STATE_UNKNOWN;
  return S_OK;
}
HRESULT Schedule(bool enabled) {
  ComPtr<ITaskService> service;
  ComPtr<ITaskFolder> folder;
  std::wstring name, sid;
  CHECK_HR(TaskFolder(&service, &folder, &name, &sid));
  if (!enabled) {
    const HRESULT removed = folder->DeleteTask(Bstr(name.c_str()), 0);
    return MissingTask(removed) ? S_OK : removed;
  }
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
  const std::wstring executable(path.data(), length);
  const std::wstring directory = executable.substr(0, executable.find_last_of(L"\\/"));
  ComPtr<ITaskDefinition> task;
  CHECK_HR(service->NewTask(0, task.GetAddressOf()));
  ComPtr<IRegistrationInfo> info;
  CHECK_HR(task->get_RegistrationInfo(info.GetAddressOf()));
  CHECK_HR(info->put_Author(Bstr(L"Triomi")));
  CHECK_HR(info->put_Description(Bstr(L"Anime and manga content checks every 12 hours and at logon. Runs only while Triomi is closed and this user is logged in.")));
  ComPtr<IPrincipal> principal;
  CHECK_HR(task->get_Principal(principal.GetAddressOf()));
  CHECK_HR(principal->put_UserId(Bstr(sid.c_str())));
  CHECK_HR(principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN));
  CHECK_HR(principal->put_RunLevel(TASK_RUNLEVEL_LUA));
  ComPtr<ITaskSettings> settings;
  CHECK_HR(task->get_Settings(settings.GetAddressOf()));
  CHECK_HR(settings->put_Enabled(VARIANT_TRUE));
  CHECK_HR(settings->put_StartWhenAvailable(VARIANT_TRUE));
  CHECK_HR(settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE));
  CHECK_HR(settings->put_StopIfGoingOnBatteries(VARIANT_FALSE));
  CHECK_HR(settings->put_RunOnlyIfNetworkAvailable(VARIANT_TRUE));
  CHECK_HR(settings->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW));
  CHECK_HR(settings->put_ExecutionTimeLimit(Bstr(L"PT2H")));
  CHECK_HR(settings->put_AllowDemandStart(VARIANT_TRUE));
  ComPtr<ITriggerCollection> triggers;
  CHECK_HR(task->get_Triggers(triggers.GetAddressOf()));
  ComPtr<ITrigger> trigger;
  CHECK_HR(triggers->Create(TASK_TRIGGER_DAILY, trigger.GetAddressOf()));
  ComPtr<IDailyTrigger> daily;
  CHECK_HR(trigger.As(&daily));
  CHECK_HR(daily->put_DaysInterval(1));
  CHECK_HR(daily->put_StartBoundary(Bstr(L"2020-01-01T03:00:00")));
  CHECK_HR(daily->put_Enabled(VARIANT_TRUE));
  ComPtr<IRepetitionPattern> repeat;
  CHECK_HR(daily->get_Repetition(repeat.GetAddressOf()));
  CHECK_HR(repeat->put_Interval(Bstr(L"PT12H")));
  CHECK_HR(repeat->put_Duration(Bstr(L"P1D")));
  CHECK_HR(repeat->put_StopAtDurationEnd(VARIANT_FALSE));
  ComPtr<ITrigger> logon_trigger;
  CHECK_HR(triggers->Create(TASK_TRIGGER_LOGON, logon_trigger.GetAddressOf()));
  ComPtr<ILogonTrigger> logon;
  CHECK_HR(logon_trigger.As(&logon));
  CHECK_HR(logon->put_UserId(Bstr(sid.c_str())));
  CHECK_HR(logon->put_Delay(Bstr(L"PT1M")));
  CHECK_HR(logon->put_Enabled(VARIANT_TRUE));
  ComPtr<IActionCollection> actions;
  CHECK_HR(task->get_Actions(actions.GetAddressOf()));
  ComPtr<IAction> action;
  CHECK_HR(actions->Create(TASK_ACTION_EXEC, action.GetAddressOf()));
  ComPtr<IExecAction> exec;
  CHECK_HR(action.As(&exec));
  CHECK_HR(exec->put_Path(Bstr(executable.c_str())));
  CHECK_HR(exec->put_Arguments(Bstr(L"--triomi-content-updates")));
  CHECK_HR(exec->put_WorkingDirectory(Bstr(directory.c_str())));
  VARIANT user, empty;
  VariantInit(&user);
  VariantInit(&empty);
  user.vt = VT_BSTR;
  user.bstrVal = SysAllocString(sid.c_str());
  ComPtr<IRegisteredTask> registered;
  const HRESULT status = folder->RegisterTaskDefinition(Bstr(name.c_str()), task.Get(),
      TASK_CREATE_OR_UPDATE, user, empty, TASK_LOGON_INTERACTIVE_TOKEN, empty,
      registered.GetAddressOf());
  VariantClear(&user);
  CHECK_HR(status);
  bool active = false;
  CHECK_HR(Scheduled(&active));
  return active ? S_OK : E_FAIL;
}

bool Constraints(const Map* args) {
  ComPtr<INetworkListManager> network;
  if (FAILED(CoCreateInstance(CLSID_NetworkListManager, nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(network.GetAddressOf())))) return false;
  VARIANT_BOOL online = VARIANT_FALSE;
  if (FAILED(network->get_IsConnectedToInternet(&online)) || online != VARIANT_TRUE) return false;
  if (Flag(args, "wifiOnly", true)) {
    ComPtr<INetworkCostManager> cost;
    DWORD value = NLM_CONNECTION_COST_UNKNOWN;
    if (FAILED(network.As(&cost)) || FAILED(cost->GetCost(&value, nullptr)) ||
        value != NLM_CONNECTION_COST_UNRESTRICTED) return false;
  }
  if (Flag(args, "batteryNotLow", true)) {
    SYSTEM_POWER_STATUS power{};
    if (!GetSystemPowerStatus(&power)) return false;
    if (power.ACLineStatus != 1 && power.BatteryFlag != 128 &&
        (power.BatteryFlag == 255 || power.BatteryLifePercent == 255 ||
         power.BatteryLifePercent <= 20 || (power.BatteryFlag & 6))) return false;
  }
  return true;
}
bool DisabledNotificationSetting(HKEY root, const wchar_t* key, const wchar_t* name,
                                 DWORD disabled_value) {
  DWORD value = 0, size = sizeof(value);
  return RegGetValueW(root, key, name, RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS &&
         value == disabled_value;
}
bool CanNotify() {
  QUERY_USER_NOTIFICATION_STATE state;
  return owner && IsWindow(owner) && FindWindowW(L"Shell_TrayWnd", nullptr) &&
      SUCCEEDED(SHQueryUserNotificationState(&state)) && state == QUNS_ACCEPTS_NOTIFICATIONS &&
      !DisabledNotificationSetting(HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", L"EnableBalloonTips", 0) &&
      !DisabledNotificationSetting(HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer", L"TaskbarNoNotification", 1);
}
void RemoveIcon() {
  if (notification_timer && owner) KillTimer(owner, notification_timer);
  notification_timer = 0;
  if (icon_added && !notifications.empty()) {
    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = owner;
    data.uID = notifications.front().id;
    Shell_NotifyIconW(NIM_DELETE, &data);
  }
  icon_added = false;
}
void FinishNotification(bool presented) {
  if (notifications.empty()) return;
  RemoveIcon();
  auto result = std::move(notifications.front().result);
  notifications.pop_front();
  if (presented) result->Success(Value(true));
  else result->Error("content_notification", "Windows did not present the desktop notification");
  // A unique icon ID rejects stale completion messages from an earlier balloon.
  // Never submit a second balloon while the first is still queued in Explorer.
  if (owner) PostMessageW(owner, kNotificationPumpMessage, 0, 0);
}
void StartNextNotification() {
  if (icon_added || notifications.empty()) return;
  if (!CanNotify()) {
    FinishNotification(false);
    return;
  }
  auto& pending = notifications.front();
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = owner;
  data.uID = pending.id;
  data.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  data.uCallbackMessage = kNotificationMessage;
  data.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(data.szTip, L"Triomi content updates");
  if (!Shell_NotifyIconW(NIM_ADD, &data)) {
    FinishNotification(false);
    return;
  }
  icon_added = true;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  wcscpy_s(data.szInfoTitle, pending.title.c_str());
  wcscpy_s(data.szInfo, pending.body.c_str());
  if (!Shell_NotifyIconW(NIM_MODIFY, &data)) {
    FinishNotification(false);
    return;
  }
  notification_timer = static_cast<UINT_PTR>(pending.id) + 0x10000000;
  // Bounded failure handling, NOT simulated delivery. Only NIN_BALLOONSHOW is
  // evidence of presentation; an unshown/expired request fails and is retriable.
  if (!SetTimer(owner, notification_timer, 60000, nullptr)) FinishNotification(false);
}
void QueueNotification(const flutter::MethodCall<Value>& call,
                       std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (call.method_name() != "notify") {
    result->NotImplemented();
    return;
  }
  if (notifications.size() >= kMaximumNotifications) {
    result->Error("content_notification_busy", "Desktop notification queue is full");
    return;
  }
  const auto args = Arguments(call);
  auto title = NotificationText("Triomi " + Text(args, "title"), 63);
  if (title.empty()) title = L"Triomi content updates";
  notifications.push_back({next_notification_id++, std::move(title),
      NotificationText(Text(args, "body"), 255), std::move(result), false});
  StartNextNotification();
}
}  // namespace

void InitializeWindowsContentUpdates(HWND window, flutter::BinaryMessenger* messenger) {
  owner = window;
  manga_channel = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "triomi/manga-updates", &flutter::StandardMethodCodec::GetInstance());
  notification_channel = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "triomi/content-notifications", &flutter::StandardMethodCodec::GetInstance());
  notification_channel->SetMethodCallHandler(QueueNotification);
}
bool HandleWindowsContentUpdates(const flutter::MethodCall<Value>& call,
                                 flutter::MethodResult<Value>* result) {
  const auto& method = call.method_name();
  const auto args = Arguments(call);
  if (method == "scheduleBackgroundCheck" || method == "scheduleMangaUpdates") {
    // Both preferences are mandatory: toggling one must never disable the other.
    if (!args || args->find(Value("backgroundCheck")) == args->end() ||
        args->find(Value("mangaUpdates")) == args->end()) {
      result->Error("content_settings", "Both content update preferences are required");
      return true;
    }
    const HRESULT hr = Schedule(Flag(args, "backgroundCheck") || Flag(args, "mangaUpdates"));
    if (FAILED(hr)) result->Error("content_schedule", "Windows content task registration failed");
    else result->Success(Value(true));
  } else if (method == "contentUpdatesScheduled" || method == "mangaUpdatesScheduled" ||
             method == "backgroundCheckScheduled") {
    bool active = false;
    const HRESULT hr = Scheduled(&active);
    if (FAILED(hr)) result->Error("content_schedule", "Cannot query Windows content task");
    else result->Success(Value(active));
  } else if (method == "mangaUpdateConstraints") {
    result->Success(Value(Constraints(args)));
  } else if (method == "beginMangaUpdate") {
    const bool acquired = !manga_running;
    if (acquired) manga_running = true;
    result->Success(Value(acquired));
  } else if (method == "endMangaUpdate") {
    manga_running = false;
    result->Success();
  } else if (method == "cancelMangaUpdate") {
    if (manga_channel) manga_channel->InvokeMethod("cancel", std::make_unique<Value>());
    result->Success();
  } else if (method == "canNotifyMangaUpdates" || method == "canNotifyContentUpdates") {
    result->Success(Value(CanNotify()));
  } else {
    return false;
  }
  return true;
}
void WindowsContentUpdatesOnMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kNotificationPumpMessage) {
    StartNextNotification();
  } else if (message == WM_TIMER && notification_timer && wparam == notification_timer) {
    FinishNotification(!notifications.empty() && notifications.front().shown);
  } else if (message == kNotificationMessage && icon_added && !notifications.empty() &&
             wparam == notifications.front().id) {
    const auto event = LOWORD(lparam);
    if (event == NIN_BALLOONSHOW) {
      notifications.front().shown = true;
    } else if (event == NIN_BALLOONHIDE || event == NIN_BALLOONTIMEOUT ||
               event == NIN_BALLOONUSERCLICK) {
      FinishNotification(notifications.front().shown);
    }
  }
}
void CloseWindowsContentUpdates() {
  RemoveIcon();
  while (!notifications.empty()) {
    auto result = std::move(notifications.front().result);
    notifications.pop_front();
    result->Error("content_notification_closed", "Desktop notification host closed before acknowledgement");
  }
  notification_channel.reset();
  manga_channel.reset();
  manga_running = false;
  owner = nullptr;
}
