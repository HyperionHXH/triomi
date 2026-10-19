#include "desktop_mihon_runtime.h"

#include <shlobj.h>
#include <tlhelp32.h>

#include <new>

#pragma comment(lib, "uuid.lib")

namespace {

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle) : handle_(handle) {}
  ~ScopedHandle() {
    if (handle_ && handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  HANDLE get() const { return handle_; }
  HANDLE release() {
    HANDLE handle = handle_;
    handle_ = nullptr;
    return handle;
  }

 private:
  HANDLE handle_;
};

HANDLE KillOnCloseJob() {
  ScopedHandle job(CreateJobObjectW(nullptr, nullptr));
  if (!job.get()) return nullptr;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
      &limits, sizeof(limits))) return nullptr;
  return job.release();
}

bool SamePath(const std::wstring& left, const std::wstring& right) {
  return CompareStringOrdinal(left.c_str(), static_cast<int>(left.size()),
      right.c_str(), static_cast<int>(right.size()), TRUE) == CSTR_EQUAL;
}

bool SameFile(HANDLE left, HANDLE right) {
  BY_HANDLE_FILE_INFORMATION left_info = {};
  BY_HANDLE_FILE_INFORMATION right_info = {};
  return GetFileInformationByHandle(left, &left_info) &&
      GetFileInformationByHandle(right, &right_info) &&
      left_info.dwVolumeSerialNumber == right_info.dwVolumeSerialNumber &&
      left_info.nFileIndexHigh == right_info.nFileIndexHigh &&
      left_info.nFileIndexLow == right_info.nFileIndexLow;
}

bool FinalPath(HANDLE file, std::wstring* path) {
  path->resize(32768);
  const DWORD count = GetFinalPathNameByHandleW(file, path->data(),
      static_cast<DWORD>(path->size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (count == 0 || count >= path->size()) return false;
  path->resize(count);
  return true;
}

bool BundledJava(std::wstring* java) {
  std::wstring executable(32768, L'\0');
  const DWORD count = GetModuleFileNameW(nullptr, executable.data(),
      static_cast<DWORD>(executable.size()));
  if (count == 0 || count >= executable.size()) return false;
  executable.resize(count);
  const auto separator = executable.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return false;
  *java = executable.substr(0, separator) +
      L"\\extension-runtime\\java\\bin\\java.exe";
  return true;
}

bool DirectChild(DWORD pid, HANDLE process) {
  FILETIME parent_created = {};
  FILETIME child_created = {};
  FILETIME exited = {};
  FILETIME kernel = {};
  FILETIME user = {};
  // A stale child's recorded parent PID can outlive that parent and later be
  // reused for this app. Require a child from this app's actual lifetime.
  if (!GetProcessTimes(GetCurrentProcess(), &parent_created, &exited, &kernel, &user) ||
      !GetProcessTimes(process, &child_created, &exited, &kernel, &user) ||
      CompareFileTime(&child_created, &parent_created) < 0) return false;
  ScopedHandle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  if (snapshot.get() == INVALID_HANDLE_VALUE) return false;
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  if (!Process32FirstW(snapshot.get(), &entry)) return false;
  do {
    if (entry.th32ProcessID == pid) {
      return entry.th32ParentProcessID == GetCurrentProcessId();
    }
  } while (Process32NextW(snapshot.get(), &entry));
  return false;
}

bool BundledJavaProcess(HANDLE process) {
  std::wstring expected;
  if (!BundledJava(&expected)) return false;
  std::wstring image(32768, L'\0');
  DWORD count = static_cast<DWORD>(image.size());
  if (!QueryFullProcessImageNameW(process, 0, image.data(), &count)) return false;
  image.resize(count);
  // Resolve both names through file handles, not textual prefixes or symlinks.
  ScopedHandle expected_file(CreateFileW(expected.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  ScopedHandle image_file(CreateFileW(image.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  std::wstring expected_path;
  std::wstring image_path;
  return expected_file.get() != INVALID_HANDLE_VALUE &&
      image_file.get() != INVALID_HANDLE_VALUE &&
      FinalPath(expected_file.get(), &expected_path) &&
      FinalPath(image_file.get(), &image_path) &&
      SamePath(expected_path, image_path) &&
      SameFile(expected_file.get(), image_file.get());
}

// State publication accepts ordinary absolute paths only. Reject device paths,
// ADS, dot segments, Win32 name trimming and ambiguous separators before I/O.
bool StatePath(const std::string& text, std::wstring* path) {
  if (text.empty() || text.size() > 32760 ||
      text.find('\0') != std::string::npos) return false;
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (!count) return false;
  path->resize(count);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), path->data(), count)) return false;
  for (wchar_t& ch : *path) {
    if (ch < 32 || ch == L'"' || ch == L'<' || ch == L'>' ||
        ch == L'|' || ch == L'?' || ch == L'*') return false;
    if (ch == L'/') ch = L'\\';
  }
  const bool drive = path->size() >= 3 &&
      (((*path)[0] >= L'A' && (*path)[0] <= L'Z') ||
       ((*path)[0] >= L'a' && (*path)[0] <= L'z')) &&
      (*path)[1] == L':' && (*path)[2] == L'\\';
  const bool unc = path->size() > 4 && path->compare(0, 2, L"\\\\") == 0;
  if (!drive && !unc) return false;
  size_t begin = drive ? 3 : 2;
  size_t components = 0;
  while (begin < path->size()) {
    const auto end = path->find(L'\\', begin);
    const auto length = (end == std::wstring::npos ? path->size() : end) - begin;
    if (length == 0 || path->compare(begin, length, L".") == 0 ||
        path->compare(begin, length, L"..") == 0 ||
        (*path)[begin + length - 1] == L'.' ||
        (*path)[begin + length - 1] == L' ' ||
        path->find(L':', begin) < begin + length) return false;
    ++components;
    if (end == std::wstring::npos) return !unc || components >= 3;
    begin = end + 1;
  }
  return false;
}

bool PlainFile(HANDLE file, DWORD* error) {
  BY_HANDLE_FILE_INFORMATION information = {};
  if (!GetFileInformationByHandle(file, &information)) {
    *error = GetLastError();
    return false;
  }
  if ((information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
      information.nNumberOfLinks != 1) {
    *error = ERROR_ACCESS_DENIED;
    return false;
  }
  return true;
}

bool AbsoluteRoot(const std::string& text, std::wstring* root) {
  if (text.empty() || text.size() > 32760 || text.find('\0') != std::string::npos) {
    return false;
  }
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (count == 0) return false;
  root->resize(count);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), root->data(), count)) return false;
  for (const wchar_t ch : *root) {
    if (ch < 32 || ch == L'"') return false;
  }
  const bool drive = root->size() >= 3 &&
      (((*root)[0] >= L'A' && (*root)[0] <= L'Z') ||
       ((*root)[0] >= L'a' && (*root)[0] <= L'z')) &&
      (*root)[1] == L':' && ((*root)[2] == L'\\' || (*root)[2] == L'/');
  const bool unc = root->size() > 4 && root->compare(0, 2, L"\\\\") == 0 &&
      (*root)[2] != L'?' && (*root)[2] != L'.';
  if (!drive && !unc) return false;
  const DWORD attributes = GetFileAttributesW(root->c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool ValidProxy(const std::string& host, int port) {
  if (host.empty()) return port == 0;
  if (port < 1 || port > 65535 || host.size() > 253) return false;
  const bool ipv6 = host.find(':') != std::string::npos;
  const bool bracketed = host.front() == '[' && host.back() == ']';
  if (bracketed && !ipv6) return false;
  const size_t begin = bracketed ? 1 : 0;
  const size_t end = host.size() - (bracketed ? 1 : 0);
  if (begin == end) return false;
  // Only bare ASCII DNS/IP host characters: no URL, credentials, whitespace,
  // zone escapes or JVM argument syntax can enter a system property.
  for (size_t index = begin; index < end; ++index) {
    const char ch = host[index];
    const bool digit = ch >= '0' && ch <= '9';
    const bool letter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
    const bool hex = digit || (ch >= 'a' && ch <= 'f') ||
        (ch >= 'A' && ch <= 'F');
    if (ipv6 ? !(hex || ch == ':' || ch == '.') :
        !(letter || digit || ch == '.' || ch == '-' || ch == '_')) return false;
  }
  return true;
}

// Windows CommandLineToArgvW quoting, including roots ending with a backslash.
std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (const wchar_t ch : value) {
    if (ch == L'\\') {
      ++slashes;
      continue;
    }
    result.append(ch == L'"' ? slashes * 2 + 1 : slashes, L'\\');
    slashes = 0;
    result.push_back(ch);
  }
  result.append(slashes * 2, L'\\');
  result.push_back(L'"');
  return result;
}

bool BundledPaths(const std::wstring& root, std::wstring* java, std::wstring* jar) {
  if (!BundledJava(java)) return false;
  // Dart reconstructs and verifies the compile-pinned upstream bytes here.
  // The immutable install payload contains <=64MiB chunks, not a large member.
  *jar = root + L"\\runtime\\suwayomi.jar";
  for (const auto* path : {java, jar}) {
    const DWORD attributes = GetFileAttributesW(path->c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) return false;
  }
  return true;
}

}  // namespace

DesktopMihonRuntime::~DesktopMihonRuntime() {
  Stop();
  if (verifier_job_) {
    TerminateJobObject(verifier_job_, 0);
    CloseHandle(verifier_job_);
  }
  for (const auto& verifier : verifiers_) CloseHandle(verifier.second);
}

bool DesktopMihonRuntime::Alive() const {
  return process_ && WaitForSingleObject(process_, 0) == WAIT_TIMEOUT;
}

bool DesktopMihonRuntime::TrackVerifier(DWORD pid) {
  if (!pid || pid == GetCurrentProcessId()) return false;
  const auto existing = verifiers_.find(pid);
  if (existing != verifiers_.end()) {
    return WaitForSingleObject(existing->second, 0) == WAIT_TIMEOUT;
  }
  // Never terminate a caller-supplied PID until both ownership and the exact
  // bundled image have been established on a retained process handle.
  ScopedHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
      PROCESS_SET_QUOTA | PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid));
  if (!process.get() || WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT ||
      !DirectChild(pid, process.get()) || !BundledJavaProcess(process.get()) ||
      WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT) return false;
  if (!verifier_job_) verifier_job_ = KillOnCloseJob();
  if (!verifier_job_ || !AssignProcessToJobObject(verifier_job_, process.get())) {
    TerminateProcess(process.get(), 1);
    return false;
  }
  // A verifier that exited while being assigned is an ordinary failed track,
  // not a reason to affect another process (including a future PID reuse).
  if (WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT) return false;
  try {
    verifiers_.emplace(pid, process.get());
  } catch (const std::bad_alloc&) {
    TerminateProcess(process.get(), 1);
    return false;
  }
  process.release();
  return true;
}

bool DesktopMihonRuntime::UntrackVerifier(DWORD pid) {
  const auto entry = verifiers_.find(pid);
  if (entry == verifiers_.end()) return false;
  CloseHandle(entry->second);
  verifiers_.erase(entry);
  // Windows keeps the process and descendants in the kill-on-close job even
  // after the tracking handle is released.
  return true;
}

bool DesktopMihonRuntime::ReplaceStateFile(const std::string& source,
                                         const std::string& destination,
                                         std::string* failure_stage, DWORD* error) {
  failure_stage->clear();
  *error = ERROR_SUCCESS;
  const auto fail = [failure_stage, error](const char* stage, DWORD code) {
    *failure_stage = stage;
    *error = code;
    return false;
  };
  std::wstring from;
  std::wstring to;
  if (!StatePath(source, &from) || !StatePath(destination, &to)) {
    return fail("validate_absolute_paths", ERROR_INVALID_PARAMETER);
  }
  const auto source_separator = from.find_last_of(L'\\');
  const auto destination_separator = to.find_last_of(L'\\');
  if (source_separator == std::wstring::npos ||
      destination_separator == std::wstring::npos ||
      from.substr(source_separator + 1) != L"state.json.part" ||
      to.substr(destination_separator + 1) != L"state.json" ||
      !SamePath(from.substr(0, source_separator),
                to.substr(0, destination_separator))) {
    return fail("validate_state_names", ERROR_INVALID_PARAMETER);
  }

  PWSTR roaming = nullptr;
  const HRESULT roaming_result = SHGetKnownFolderPath(
      FOLDERID_RoamingAppData, 0, nullptr, &roaming);
  if (FAILED(roaming_result)) {
    return fail("resolve_app_support", HRESULT_CODE(roaming_result));
  }
  // Match path_provider_windows' CompanyName/ProductName support directory.
  const std::wstring expected = std::wstring(roaming) +
      L"\\io.github.hyperionhxh\\triomi\\mihon-desktop";
  CoTaskMemFree(roaming);
  ScopedHandle expected_directory(CreateFileW(expected.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (expected_directory.get() == INVALID_HANDLE_VALUE) {
    return fail("open_app_support", GetLastError());
  }
  ScopedHandle directory(CreateFileW(from.substr(0, source_separator).c_str(),
      FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr));
  if (directory.get() == INVALID_HANDLE_VALUE) {
    return fail("open_parent", GetLastError());
  }
  BY_HANDLE_FILE_INFORMATION information = {};
  if (!GetFileInformationByHandle(directory.get(), &information)) {
    return fail("inspect_parent", GetLastError());
  }
  if (!(information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    return fail("validate_parent_type", ERROR_ACCESS_DENIED);
  }
  std::wstring parent;
  std::wstring expected_parent;
  if (!FinalPath(directory.get(), &parent) ||
      !FinalPath(expected_directory.get(), &expected_parent)) {
    return fail("resolve_parent", GetLastError());
  }
  if (!SamePath(parent, expected_parent) ||
      !SameFile(directory.get(), expected_directory.get())) {
    return fail("validate_app_support_parent", ERROR_ACCESS_DENIED);
  }

  // Operate through the resolved, pinned parent, never caller-provided aliases.
  from = parent + L"\\state.json.part";
  to = parent + L"\\state.json";
  ScopedHandle candidate(CreateFileW(from.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (candidate.get() == INVALID_HANDLE_VALUE) {
    return fail("open_candidate", GetLastError());
  }
  DWORD inspection_error = ERROR_SUCCESS;
  if (!PlainFile(candidate.get(), &inspection_error)) {
    return fail("validate_candidate", inspection_error);
  }
  ScopedHandle current(CreateFileW(to.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (current.get() == INVALID_HANDLE_VALUE) {
    const DWORD open_error = GetLastError();
    if (open_error != ERROR_FILE_NOT_FOUND) return fail("open_destination", open_error);
  } else {
    if (!PlainFile(current.get(), &inspection_error)) {
      return fail("validate_destination", inspection_error);
    }
    // MoveFileEx replacement rejects an open destination even when that handle
    // shares DELETE. Finish inspection before atomically replacing its name.
    if (!CloseHandle(current.release())) {
      return fail("close_destination", GetLastError());
    }
  }
  // No pre-delete and no cross-volume fallback: failure leaves the old state
  // intact; WRITE_THROUGH completes the atomic rename before reporting success.
  if (!MoveFileExW(from.c_str(), to.c_str(),
      MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    return fail("replace_state", GetLastError());
  }
  return true;
}

void DesktopMihonRuntime::Stop() {
  if (job_) {
    TerminateJobObject(job_, 0);
    // Release the JVM's file/port handles before a subsequent Start reuses root.
    if (process_) WaitForSingleObject(process_, 5000);
    CloseHandle(job_);
    job_ = nullptr;
  }
  if (process_) {
    CloseHandle(process_);
    process_ = nullptr;
  }
  pid_ = 0;
}

bool DesktopMihonRuntime::Start(const std::string& text,
                               const std::string& proxy_host,
                               int proxy_port, DWORD* pid) {
  if (!ValidProxy(proxy_host, proxy_port)) return false;
  if (Alive()) {
    *pid = pid_;
    return true;
  }
  Stop();
  std::wstring root;
  std::wstring java;
  std::wstring jar;
  if (!AbsoluteRoot(text, &root) || !BundledPaths(root, &java, &jar)) return false;

  std::wstring command = Quote(java) + L" -Xmx384m -Djava.awt.headless=true " +
      Quote(L"-Dsuwayomi.tachidesk.config.server.rootDir=" + root);
  if (!proxy_host.empty()) {
    const std::wstring host(proxy_host.begin(), proxy_host.end());
    const std::wstring port = std::to_wstring(proxy_port);
    command += L" " + Quote(L"-Dhttp.proxyHost=" + host) +
        L" " + Quote(L"-Dhttps.proxyHost=" + host) +
        L" " + Quote(L"-Dhttp.proxyPort=" + port) +
        L" " + Quote(L"-Dhttps.proxyPort=" + port) +
        L" " + Quote(L"-Dhttp.nonProxyHosts=127.*|localhost|[::1]");
  }
  command += L" -jar " + Quote(jar);
  // CreateJobObject's default security attributes do not permit inheritance.
  HANDLE job = KillOnCloseJob();
  if (!job) return false;
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process = {};
  // Suspension closes the spawn/assignment race: no JVM or APK code can run
  // until it belongs to our kill-on-close job. No handles are inherited.
  if (!CreateProcessW(java.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, root.c_str(), &startup, &process)) {
    CloseHandle(job);
    return false;
  }
  if (!AssignProcessToJobObject(job, process.hProcess) ||
      ResumeThread(process.hThread) == static_cast<DWORD>(-1)) {
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    return false;
  }
  CloseHandle(process.hThread);
  job_ = job;
  process_ = process.hProcess;
  pid_ = process.dwProcessId;
  *pid = pid_;
  return true;
}
