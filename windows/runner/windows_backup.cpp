#include "windows_backup.h"

#include <sddl.h>
#include <taskschd.h>
#include <wrl/client.h>

#include <vector>

namespace {
using Microsoft::WRL::ComPtr;

class Bstr {
 public:
  explicit Bstr(const wchar_t* text) : value_(::SysAllocString(text)) {}
  ~Bstr() { ::SysFreeString(value_); }
  operator BSTR() const { return value_; }
 private:
  BSTR value_;
};

HRESULT CurrentUserSid(std::wstring* sid) {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return HRESULT_FROM_WIN32(::GetLastError());
  }
  DWORD length = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  std::vector<BYTE> bytes(length);
  const bool read = ::GetTokenInformation(token, TokenUser, bytes.data(),
                                         length, &length) != FALSE;
  const DWORD error = read ? ERROR_SUCCESS : ::GetLastError();
  ::CloseHandle(token);
  if (!read) return HRESULT_FROM_WIN32(error);
  LPWSTR text = nullptr;
  if (!::ConvertSidToStringSidW(
          reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid, &text)) {
    return HRESULT_FROM_WIN32(::GetLastError());
  }
  *sid = text;
  ::LocalFree(text);
  return S_OK;
}

HRESULT ExecutablePath(std::wstring* path) {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = ::GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (!length || length >= buffer.size()) {
    return HRESULT_FROM_WIN32(length ? ERROR_INSUFFICIENT_BUFFER : ::GetLastError());
  }
  path->assign(buffer.data(), length);
  return S_OK;
}

// Stop immediately on a native scheduling error. The Dart caller only saves an
// enabled preference after registration reports success.
#define RETURN_IF_FAILED(expression) \
  do { const HRESULT status = (expression); if (FAILED(status)) return status; } while (false)
}  // namespace

ProfileOwnership::~ProfileOwnership() {
  if (mutex_) {
    ::ReleaseMutex(mutex_);
    ::CloseHandle(mutex_);
  }
}

bool ProfileOwnership::Acquire() {
  std::wstring sid;
  if (FAILED(CurrentUserSid(&sid))) return false;
  // Global crosses this user's simultaneous Windows sessions. The SID avoids
  // contention with another user's separate documents/profile directories.
  const std::wstring name = L"Global\\TriomiProfileWriter-" + sid;
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, name.c_str());
  if (!mutex) return false;
  const DWORD result = ::WaitForSingleObject(mutex, 0);
  if (result != WAIT_OBJECT_0 && result != WAIT_ABANDONED) {
    ::CloseHandle(mutex);
    return false;
  }
  mutex_ = mutex;
  return true;
}

HRESULT SetLocalBackupSchedule(bool enabled) {
  std::wstring sid;
  RETURN_IF_FAILED(CurrentUserSid(&sid));
  const std::wstring name = L"TriomiLocalBackup-" + sid;
  ComPtr<ITaskService> service;
  RETURN_IF_FAILED(::CoCreateInstance(CLSID_TaskScheduler, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(service.GetAddressOf())));
  VARIANT empty;
  ::VariantInit(&empty);
  RETURN_IF_FAILED(service->Connect(empty, empty, empty, empty));
  ComPtr<ITaskFolder> root;
  RETURN_IF_FAILED(service->GetFolder(Bstr(L"\\"), root.GetAddressOf()));
  if (!enabled) {
    const HRESULT removed = root->DeleteTask(Bstr(name.c_str()), 0);
    // Cancellation is idempotent, but never mask permission/service errors.
    return removed == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
           removed == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND) ? S_OK : removed;
  }

  std::wstring executable;
  RETURN_IF_FAILED(ExecutablePath(&executable));
  const std::wstring working_directory =
      executable.substr(0, executable.find_last_of(L"\\/"));
  ComPtr<ITaskDefinition> task;
  RETURN_IF_FAILED(service->NewTask(0, task.GetAddressOf()));
  ComPtr<IRegistrationInfo> registration;
  RETURN_IF_FAILED(task->get_RegistrationInfo(registration.GetAddressOf()));
  RETURN_IF_FAILED(registration->put_Author(Bstr(L"Triomi")));
  RETURN_IF_FAILED(registration->put_Description(Bstr(
      L"Daily metadata-only local backup. Runs only while Triomi is closed; no network or credentials.")));
  ComPtr<IPrincipal> principal;
  RETURN_IF_FAILED(task->get_Principal(principal.GetAddressOf()));
  RETURN_IF_FAILED(principal->put_UserId(Bstr(sid.c_str())));
  RETURN_IF_FAILED(principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN));
  RETURN_IF_FAILED(principal->put_RunLevel(TASK_RUNLEVEL_LUA));

  ComPtr<ITaskSettings> settings;
  RETURN_IF_FAILED(task->get_Settings(settings.GetAddressOf()));
  RETURN_IF_FAILED(settings->put_Enabled(VARIANT_TRUE));
  RETURN_IF_FAILED(settings->put_StartWhenAvailable(VARIANT_TRUE));
  RETURN_IF_FAILED(settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE));
  RETURN_IF_FAILED(settings->put_StopIfGoingOnBatteries(VARIANT_FALSE));
  RETURN_IF_FAILED(settings->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW));
  RETURN_IF_FAILED(settings->put_ExecutionTimeLimit(Bstr(L"PT1H")));
  RETURN_IF_FAILED(settings->put_AllowDemandStart(VARIANT_TRUE));

  ComPtr<ITriggerCollection> triggers;
  RETURN_IF_FAILED(task->get_Triggers(triggers.GetAddressOf()));
  ComPtr<ITrigger> trigger;
  RETURN_IF_FAILED(triggers->Create(TASK_TRIGGER_DAILY, trigger.GetAddressOf()));
  ComPtr<IDailyTrigger> daily;
  RETURN_IF_FAILED(trigger.As(&daily));
  RETURN_IF_FAILED(daily->put_DaysInterval(1));
  // No UTC suffix: local wall time, including Windows time-zone/DST changes.
  RETURN_IF_FAILED(daily->put_StartBoundary(Bstr(L"2020-01-01T03:00:00")));
  RETURN_IF_FAILED(daily->put_Enabled(VARIANT_TRUE));
  ComPtr<ITrigger> login_trigger;
  RETURN_IF_FAILED(triggers->Create(TASK_TRIGGER_LOGON, login_trigger.GetAddressOf()));
  ComPtr<ILogonTrigger> login;
  RETURN_IF_FAILED(login_trigger.As(&login));
  RETURN_IF_FAILED(login->put_UserId(Bstr(sid.c_str())));
  RETURN_IF_FAILED(login->put_Delay(Bstr(L"PT1M")));
  RETURN_IF_FAILED(login->put_Enabled(VARIANT_TRUE));

  ComPtr<IActionCollection> actions;
  RETURN_IF_FAILED(task->get_Actions(actions.GetAddressOf()));
  ComPtr<IAction> action;
  RETURN_IF_FAILED(actions->Create(TASK_ACTION_EXEC, action.GetAddressOf()));
  ComPtr<IExecAction> exec;
  RETURN_IF_FAILED(action.As(&exec));
  // COM stores executable/arguments separately, safely preserving spaces,
  // Unicode, &, quotes in ancestor paths and other shell metacharacters.
  RETURN_IF_FAILED(exec->put_Path(Bstr(executable.c_str())));
  RETURN_IF_FAILED(exec->put_Arguments(Bstr(L"--triomi-local-backup")));
  RETURN_IF_FAILED(exec->put_WorkingDirectory(Bstr(working_directory.c_str())));
  VARIANT user;
  ::VariantInit(&user);
  user.vt = VT_BSTR;
  user.bstrVal = ::SysAllocString(sid.c_str());
  ComPtr<IRegisteredTask> registered;
  const HRESULT result = root->RegisterTaskDefinition(Bstr(name.c_str()),
      task.Get(), TASK_CREATE_OR_UPDATE, user, empty,
      TASK_LOGON_INTERACTIVE_TOKEN, empty, registered.GetAddressOf());
  ::VariantClear(&user);
  if (FAILED(result)) return result;
  VARIANT_BOOL active = VARIANT_FALSE;
  RETURN_IF_FAILED(registered->get_Enabled(&active));
  return active == VARIANT_TRUE ? S_OK : E_FAIL;
}
