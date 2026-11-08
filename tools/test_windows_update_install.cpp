// Compile this console program independently of Flutter, with its dedicated
// version resource. Writes only an exclusive temporary tree and the preserved/
// restored 0.0.0+0 installer-revision test value, never a production version key.
// Usage: test_windows_update_install.exe <built triomi_update_helper.exe>
#include "../windows/runner/windows_update_common.h"
#include "../windows/runner/windows_update_revision.h"
#include <cstdio>
#include <iterator>

namespace {
using namespace triomi_update;
void Directory(const std::wstring& path) {
  Require(CreateDirectoryW(path.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS,
      "Smoke directory creation failed");
}
void TextFile(const std::wstring& path, const std::string& text) {
  auto h = NewFile(path);
  WriteAll(h.get(), text.data(), static_cast<DWORD>(text.size()));
}
std::string ReadText(const std::wstring& path) {
  Handle h(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Require(static_cast<bool>(h) && Size(h.get()) < 65536, "Cannot read bounded smoke result");
  std::string result(static_cast<size_t>(Size(h.get())), '\0');
  DWORD n = 0;
  Require(ReadFile(h.get(), result.data(), static_cast<DWORD>(result.size()), &n, nullptr) && n == result.size(),
      "Cannot read smoke result bytes");
  return result;
}
void CopyPath(const std::wstring& source, const std::wstring& target) {
  auto from = ReadFilePinned(source, false);
  auto to = NewFile(target);
  Copy(from.get(), to.get());
}
Handle Process(const std::wstring& executable, const std::wstring& arguments) {
  std::wstring command = Quote(executable) + arguments;
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  Require(CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, Parent(executable).c_str(), &startup, &process) != FALSE,
      "Cannot start isolated smoke parent");
  Handle thread(process.hThread);
  return Handle(process.hProcess);
}
struct Case {
  std::wstring root, stop_name;
  Plan plan;
  Handle stop, parent;
  Case(const std::wstring& suite, const wchar_t* name, const std::wstring& helper) {
    root = suite + L"\\" + name;
    Directory(root); Directory(root + L"\\install"); Directory(root + L"\\support");
    Directory(root + L"\\support\\app-update");
    const auto bundle = root + L"\\support\\app-update\\bundle-smoke";
    Directory(bundle);
    plan.executable = root + L"\\install\\triomi.exe";
    plan.payload = bundle + L"\\payload-smoke";
    plan.stage = bundle + L"\\install-smoke";
    Directory(plan.payload); Directory(plan.stage);
    CopyPath(Image(), plan.executable);
    CopyPath(helper, root + L"\\install\\" + kHelperName);
    CopyPath(Image(), plan.payload + L"\\triomi.exe");
    CopyPath(helper, plan.payload + L"\\" + kHelperName);
    TextFile(root + L"\\install\\a.txt", "old bytes");
    TextFile(root + L"\\install\\unrelated.txt", "keep unrelated");
    TextFile(plan.payload + L"\\a.txt", "new bytes");
    for (const auto& path : {std::wstring(L"a.txt"), std::wstring(L"triomi.exe"), std::wstring(kHelperName)}) Add(path);
    stop_name = Unique(L"Local\\TriomiUpdateSmoke-");
    stop.reset(CreateEventW(nullptr, TRUE, FALSE, stop_name.c_str()));
    Require(static_cast<bool>(stop), "Cannot create smoke parent stop event");
    parent = Process(plan.executable, L" --test-parent " + Quote(stop_name));
  }
  void Add(const std::wstring& path) {
    auto file = ReadFilePinned(plan.payload + L"\\" + path, true);
    plan.files.push_back(File{path, Size(file.get()), Digest(file.get())});
  }
  void Stop() {
    Require(SetEvent(stop.get()) != FALSE && WaitForSingleObject(parent.get(), 10000) == WAIT_OBJECT_0,
        "Smoke parent did not exit");
  }
  ~Case() {
    if (stop) SetEvent(stop.get());
    if (parent && WaitForSingleObject(parent.get(), 10000) == WAIT_TIMEOUT) TerminateProcess(parent.get(), 2);
  }
};
struct FailureDialog {
  DWORD pid;
  std::wstring outcome;
  bool seen = false;
  bool contains_outcome = false;
  std::wstring observed_text;
};
BOOL CALLBACK FindOutcomeText(HWND child, LPARAM parameter) {
  auto* dialog = reinterpret_cast<FailureDialog*>(parameter);
  wchar_t text[2048]{};
  DWORD_PTR length = 0;
  // GetWindowText does not reliably retrieve another process's controls.
  // WM_GETTEXT is the supported cross-process read; bound hung-control waits.
  if (!SendMessageTimeoutW(child, WM_GETTEXT, std::size(text), reinterpret_cast<LPARAM>(text),
      SMTO_ABORTIFHUNG | SMTO_BLOCK, 250, &length)) return TRUE;
  if (length >= std::size(text)) length = std::size(text) - 1;
  if (length && dialog->observed_text.size() < 4096) {
    dialog->observed_text.append(text, static_cast<size_t>(length));
    dialog->observed_text += L"\n";
  }
  if (length > 0 && std::wstring(text, static_cast<size_t>(length)).find(dialog->outcome) != std::wstring::npos)
    dialog->contains_outcome = true;
  return TRUE;
}
BOOL CALLBACK DismissOwnedFailure(HWND window, LPARAM parameter) {
  auto* dialog = reinterpret_cast<FailureDialog*>(parameter);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid != dialog->pid) return TRUE;
  wchar_t title[64]{}, type[32]{};
  GetWindowTextW(window, title, static_cast<int>(std::size(title)));
  GetClassNameW(window, type, static_cast<int>(std::size(type)));
  if (!IsWindowVisible(window)) return TRUE;
  if (std::wstring(type) != L"#32770" || std::wstring(title) != L"Triomi update failed") return TRUE;
  // Test-only UI automation, restricted to this exact held helper process.
  // Production has no flag, environment variable, or protocol UI bypass.
  EnumChildWindows(window, FindOutcomeText, parameter);
  dialog->seen = true;
  // Always dismiss our identified helper dialog, even if its body is wrong.
  // Validate the captured body after process exit, rather than leaving a modal
  // child stranded and replacing the useful mismatch with a timeout.
  // BM_CLICK can be ignored for an inactive dialog. WM_CLOSE acknowledges this
  // MB_OK-only MessageBox without stealing focus from the user's application.
  PostMessageW(window, WM_CLOSE, 0, 0);
  return TRUE;
}
DWORD Finish(HANDLE helper) {
  FailureDialog dialog{GetProcessId(helper), Parent(Image(helper)) + L"\\outcome.txt"};
  const ULONGLONG deadline = GetTickCount64() + 30000;
  DWORD wait = WAIT_TIMEOUT;
  while ((wait = WaitForSingleObject(helper, 20)) == WAIT_TIMEOUT && GetTickCount64() < deadline)
    EnumWindows(DismissOwnedFailure, reinterpret_cast<LPARAM>(&dialog));
  Require(wait == WAIT_OBJECT_0, "Smoke helper did not finish within 30 seconds");
  DWORD result = STILL_ACTIVE;
  Require(GetExitCodeProcess(helper, &result) != FALSE, "Cannot read smoke helper exit code");
  if (result != 0 && (!dialog.seen || !dialog.contains_outcome))
    std::fwprintf(stderr, L"Helper %lu failure dialog: seen=%d; expected outcome=%ls\nObserved controls:\n%ls\n",
        dialog.pid, dialog.seen ? 1 : 0, dialog.outcome.c_str(), dialog.observed_text.c_str());
  Require(result == 0 || (dialog.seen && dialog.contains_outcome),
      "Failed helper did not display native failure UI with its exact outcome path");
  return result;
}
void Restarted(const Case& test) {
  const auto marker = test.root + L"\\install\\restart.marker";
  const ULONGLONG deadline = GetTickCount64() + 10000;
  while (GetTickCount64() < deadline && GetFileAttributesW(marker.c_str()) == INVALID_FILE_ATTRIBUTES) Sleep(20);
  Require(ReadText(marker) == "restarted", "Exact installed smoke executable did not restart");
  Require(ReadText(test.root + L"\\install\\unrelated.txt") == "keep unrelated", "Updater changed an unrelated file");
}
// A denied CREATE_NEW in the last member's directory fails after earlier
// replacements have been copied, exercising real rollback, without test hooks.
class DenyCreate {
 public:
  explicit DenyCreate(const std::wstring& path) : path_(path) {
    DWORD error = GetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION, nullptr, nullptr, &old_, nullptr, &descriptor_);
    Require(error == ERROR_SUCCESS, "Cannot capture isolated smoke DACL");
    const auto sid = UserSid();
    EXPLICIT_ACCESSW deny{};
    deny.grfAccessPermissions = FILE_ADD_FILE;
    deny.grfAccessMode = DENY_ACCESS; deny.grfInheritance = NO_INHERITANCE;
    deny.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    deny.Trustee.TrusteeType = TRUSTEE_IS_USER;
    deny.Trustee.ptstrName = reinterpret_cast<LPWSTR>(const_cast<BYTE*>(sid.data()));
    PACL acl = nullptr;
    Require(SetEntriesInAclW(1, &deny, old_, &acl) == ERROR_SUCCESS, "Cannot construct isolated denied-write DACL");
    error = SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, acl, nullptr);
    LocalFree(acl);
    Require(error == ERROR_SUCCESS, "Cannot apply isolated denied-write DACL");
  }
  ~DenyCreate() {
    if (descriptor_) {
      SetNamedSecurityInfoW(const_cast<wchar_t*>(path_.c_str()), SE_FILE_OBJECT,
          DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, old_, nullptr);
      LocalFree(descriptor_);
    }
  }
 private:
  std::wstring path_;
  PACL old_ = nullptr;
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
};
class SmokeRegistry {
 public:
  SmokeRegistry() {
    Require(RegCreateKeyExW(HKEY_CURRENT_USER,
        L"Software\\Triomi\\Installer\\Versions\\0.0.0+0", 0, nullptr, 0,
        KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, key_.put(), nullptr) == ERROR_SUCCESS,
        "Cannot open isolated smoke servicing key");
    DWORD size = 0;
    LSTATUS status = RegQueryValueExW(key_.get(), L"InstalledWindowsRevision", nullptr, &type_, nullptr, &size);
    existed_ = status != ERROR_FILE_NOT_FOUND;
    if (existed_) {
      Require(status == ERROR_SUCCESS && size <= 65536, "Cannot preserve original smoke servicing value");
      original_.resize(size);
      Require(RegQueryValueExW(key_.get(), L"InstalledWindowsRevision", nullptr, &type_,
          original_.data(), &size) == ERROR_SUCCESS && size == original_.size(),
          "Cannot capture original smoke servicing bytes");
      Require(RegDeleteValueW(key_.get(), L"InstalledWindowsRevision") == ERROR_SUCCESS,
          "Cannot initialize isolated smoke servicing value");
    }
    active_ = true;
  }
  ~SmokeRegistry() {
    if (active_ && RestoreValue() != ERROR_SUCCESS)
      std::fputs("WARNING: could not restore isolated 0.0.0+0 smoke servicing value\n", stderr);
  }
  std::wstring Value() const {
    wchar_t text[32]{};
    DWORD type = 0, size = sizeof(text);
    Require(RegQueryValueExW(key_.get(), L"InstalledWindowsRevision", nullptr, &type,
        reinterpret_cast<BYTE*>(text), &size) == ERROR_SUCCESS && type == REG_SZ &&
        size >= sizeof(wchar_t) && size <= sizeof(text) && size % sizeof(wchar_t) == 0 &&
        text[size / sizeof(wchar_t) - 1] == L'\0', "Smoke servicing value is not a bounded REG_SZ");
    return std::wstring(text, size / sizeof(wchar_t) - 1);
  }
  void SeedHigherRevision() {
    const wchar_t value[] = L"7";
    Require(RegSetValueExW(key_.get(), L"InstalledWindowsRevision", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(value), sizeof(value)) == ERROR_SUCCESS,
        "Cannot seed isolated servicing max-revision regression");
  }
  void Restore() {
    Require(RestoreValue() == ERROR_SUCCESS, "Cannot restore original isolated smoke servicing value");
    active_ = false;
  }
 private:
  LSTATUS RestoreValue() {
    if (existed_) return RegSetValueExW(key_.get(), L"InstalledWindowsRevision", 0, type_,
        original_.data(), static_cast<DWORD>(original_.size()));
    const LSTATUS status = RegDeleteValueW(key_.get(), L"InstalledWindowsRevision");
    return status == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : status;
  }
  RegistryKey key_;
  DWORD type_ = 0;
  bool existed_ = false, active_ = false;
  std::vector<BYTE> original_;
};
void Run(const std::wstring& helper) {
  const auto own_revision = ReadInstalledRevision(Image());
  Require(own_revision.version == L"0.0.0+0" && own_revision.revision == 1,
      "Compile and link tools/test_windows_update_install.rc before running this smoke suite");
  SmokeRegistry servicing;
  wchar_t temp[241]{};
  const DWORD length = GetTempPathW(240, temp);
  Require(length && length < 240, "Cannot locate bounded temporary directory");
  std::wstring base(temp);
  if (base.back() == L'\\') base.pop_back();
  const auto suite = Unique(base + L"\\triomi-update-smoke-");
  Directory(suite);
  std::wprintf(L"Isolated smoke results: %ls\n", suite.c_str());
  {
    Case test(suite, L"success", helper);
    auto child = StartHelper(test.plan, test.parent.get(), helper);
    Require(GetFileAttributesW((Parent(test.plan.payload) + L"\\installing").c_str()) != INVALID_FILE_ATTRIBUTES,
        "Active helper did not protect its bundle");
    Require(WaitForSingleObject(child.get(), 250) == WAIT_TIMEOUT, "Helper did not wait for its exact parent");
    Require(ReadText(test.root + L"\\install\\a.txt") == "old bytes", "Updater wrote before parent exit");
    test.Stop();
    Require(Finish(child.get()) == 0, "Success helper failed");
    Require(GetFileAttributesW((Parent(test.plan.payload) + L"\\installing").c_str()) == INVALID_FILE_ATTRIBUTES,
        "Terminal helper did not remove its bundle marker");
    Require(ReadText(test.root + L"\\install\\a.txt") == "new bytes", "Update bytes were not installed");
    Require(ReadText(test.plan.stage + L"\\outcome.txt").find("success\n") == 0, "Success outcome missing");
    Restarted(test);
    Require(servicing.Value() == L"1", "Successful helper did not record actual installed PE revision");
    servicing.SeedHigherRevision();
    RecordInstalledRevision(test.plan.executable);
    Require(servicing.Value() == L"7", "Servicing persistence lowered a previously recorded maximum");
  }
  {
    Case test(suite, L"hash-mismatch", helper);
    test.plan.files.front().hash[0] ^= 0xff;
    bool rejected = false;
    try { auto child = StartHelper(test.plan, test.parent.get(), helper); }
    catch (const std::runtime_error&) { rejected = true; }
    Require(rejected && ReadText(test.root + L"\\install\\a.txt") == "old bytes", "Hash mismatch was not rejected safely");
    test.Stop();
  }
  {
    Case test(suite, L"locked", helper);
    auto child = StartHelper(test.plan, test.parent.get(), helper);
    auto locked = ReadFilePinned(test.root + L"\\install\\a.txt", false);
    test.Stop();
    Require(Finish(child.get()) != 0, "Locked destination update unexpectedly succeeded");
    Require(ReadText(test.root + L"\\install\\a.txt") == "old bytes", "Locked destination was modified");
    Restarted(test);
  }
  {
    Case test(suite, L"rollback", helper);
    Directory(test.plan.payload + L"\\zdenied");
    Directory(test.root + L"\\install\\zdenied");
    TextFile(test.plan.payload + L"\\zdenied\\z.txt", "must not install");
    test.Add(L"zdenied\\z.txt");
    auto child = StartHelper(test.plan, test.parent.get(), helper);
    DenyCreate deny(test.root + L"\\install\\zdenied");
    test.Stop();
    Require(Finish(child.get()) != 0, "Denied destination update unexpectedly succeeded");
    Require(ReadText(test.root + L"\\install\\a.txt") == "old bytes", "Earlier replacement was not rolled back");
    Require(ReadText(test.plan.stage + L"\\outcome.txt").find("rolled_back\n") == 0, "Rollback outcome missing");
    Require(GetFileAttributesW((test.root + L"\\install\\zdenied\\z.txt").c_str()) == INVALID_FILE_ATTRIBUTES,
        "Failed new file was left installed");
    Restarted(test);
  }
  {
    Case test(suite, L"second-writer", helper);
    auto child = StartHelper(test.plan, test.parent.get(), helper);
    const auto sid = UserSid(); LPWSTR raw = nullptr;
    Require(ConvertSidToStringSidW(const_cast<BYTE*>(sid.data()), &raw) != FALSE, "Cannot name test writer mutex");
    const std::wstring name = std::wstring(L"Global\\TriomiProfileWriter-") + raw;
    LocalFree(raw);
    Handle mutex(CreateMutexW(nullptr, FALSE, name.c_str()));
    const DWORD acquired = WaitForSingleObject(mutex.get(), 0);
    Require(acquired == WAIT_OBJECT_0 || acquired == WAIT_ABANDONED,
        "A real Triomi writer is running; stop it before isolated writer-contention smoke");
    test.Stop();
    const DWORD exit = Finish(child.get());
    ReleaseMutex(mutex.get());
    Require(exit != 0 && ReadText(test.root + L"\\install\\a.txt") == "old bytes",
        "Second profile writer did not prevent installation");
  }
  {
    Case test(suite, L"invalid-paths", helper);
    bool rejected = false;
    try { Relative(L"../outside"); } catch (const std::runtime_error&) { rejected = true; }
    Require(rejected, "Traversal path accepted");
    test.plan.files.push_back(test.plan.files.front());
    test.plan.files.back().path = L"A.TXT";
    rejected = false;
    try { ValidatePlan(test.plan); } catch (const std::runtime_error&) { rejected = true; }
    Require(rejected, "Case-duplicate member accepted");
    test.Stop();
  }
  servicing.Restore();
  std::puts("PASS: parent wait, verified copy/restart, servicing persistence/max preservation, hash rejection, locked target, mid-copy rollback, native failure dialogs, writer contention, path rejection");
  // Preserve the exclusive tree as evidence. No recursive deletion of app,
  // profile, Documents or support data is part of this smoke program.
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  try {
    if (argc == 3 && std::wstring(argv[1]) == L"--test-parent") {
      Handle stop(OpenEventW(SYNCHRONIZE, FALSE, argv[2]));
      Require(static_cast<bool>(stop) && WaitForSingleObject(stop.get(), 120000) == WAIT_OBJECT_0,
          "Isolated fake parent stop failed");
      return 0;
    }
    if (argc == 1 && Same(Leaf(Image()), L"triomi.exe")) {
      TextFile(Parent(Image()) + L"\\restart.marker", "restarted");
      return 0;
    }
    Require(argc == 2, "Usage: test_windows_update_install.exe <triomi_update_helper.exe>");
    Run(Absolute(argv[1]));
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  }
}
