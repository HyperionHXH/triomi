#ifndef RUNNER_WINDOWS_UPDATE_COMMON_H_
#define RUNNER_WINDOWS_UPDATE_COMMON_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// Private, bounded protocol shared by the app and its separately staged helper.
// Hashes establish content integrity, not publisher authenticity.
namespace triomi_update {
constexpr uint64_t kMemberLimit = 128ull * 1024 * 1024;
constexpr uint64_t kTotalLimit = 1024ull * 1024 * 1024;
constexpr uint32_t kFileLimit = 10000;
constexpr uint32_t kPlanLimit = 8 * 1024 * 1024;
constexpr DWORD kParentTimeout = 120000;
constexpr wchar_t kHelperName[] = L"triomi_update_helper.exe";

[[noreturn]] inline void Fail(const char* text) { throw std::runtime_error(text); }
inline void Require(bool condition, const char* text) { if (!condition) Fail(text); }
class Handle {
 public:
  explicit Handle(HANDLE h = nullptr) : h_(h) {}
  ~Handle() { reset(); }
  Handle(Handle&& other) noexcept : h_(other.release()) {}
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) { reset(); h_ = other.release(); }
    return *this;
  }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return h_; }
  explicit operator bool() const { return h_ && h_ != INVALID_HANDLE_VALUE; }
  HANDLE release() { HANDLE h = h_; h_ = nullptr; return h; }
  void reset(HANDLE h = nullptr) {
    if (*this) CloseHandle(h_);
    h_ = h;
  }
 private:
  HANDLE h_;
};
inline bool Same(const std::wstring& a, const std::wstring& b) {
  return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
      b.c_str(), static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}
struct Less {
  bool operator()(const std::wstring& a, const std::wstring& b) const {
    return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
        b.c_str(), static_cast<int>(b.size()), TRUE) == CSTR_LESS_THAN;
  }
};
inline bool Within(const std::wstring& path, const std::wstring& root) {
  return Same(path, root) || (path.size() > root.size() &&
      path[root.size()] == L'\\' && Same(path.substr(0, root.size()), root));
}
inline std::wstring Parent(const std::wstring& p) { return p.substr(0, p.find_last_of(L'\\')); }
inline std::wstring Leaf(const std::wstring& p) { return p.substr(p.find_last_of(L'\\') + 1); }
inline std::wstring Wide(const std::string& s) {
  Require(!s.empty() && s.size() <= 32760 && s.find('\0') == std::string::npos,
      "Update text is empty or too long");
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
  Require(n > 0, "Update text is not UTF-8");
  std::wstring result(n, L'\0');
  Require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), result.data(), n) == n,
      "Update text conversion failed");
  return result;
}
inline void Component(const std::wstring& s) {
  Require(!s.empty() && s.size() <= 120 && s != L"." && s != L".." &&
      s.back() != L'.' && s.back() != L' ', "Unsafe update path component");
  for (wchar_t c : s) Require(c >= 32 && c != L'<' && c != L'>' && c != L':' && c != L'"' &&
      c != L'/' && c != L'\\' && c != L'|' && c != L'?' && c != L'*', "Unsafe update path character");
  std::wstring base = s.substr(0, s.find(L'.'));
  while (!base.empty() && base.back() == L' ') base.pop_back();
  Require(!Same(base, L"CON") && !Same(base, L"PRN") && !Same(base, L"AUX") && !Same(base, L"NUL") &&
      !Same(base, L"CONIN$") && !Same(base, L"CONOUT$"), "Reserved update filename");
  if (base.size() == 4 && (Same(base.substr(0, 3), L"COM") || Same(base.substr(0, 3), L"LPT"))) {
    wchar_t c = base[3];
    Require(!((c >= L'0' && c <= L'9') || c == 0xb9 || c == 0xb2 || c == 0xb3), "Reserved update filename");
  }
}
inline std::wstring Relative(std::wstring s) {
  Require(!s.empty() && s.size() <= 220, "Update member path is too long");
  std::replace(s.begin(), s.end(), L'/', L'\\');
  size_t begin = 0;
  for (;;) {
    size_t end = s.find(L'\\', begin);
    Component(s.substr(begin, end == std::wstring::npos ? end : end - begin));
    if (end == std::wstring::npos) break;
    begin = end + 1;
  }
  return s;
}
inline std::wstring Absolute(std::wstring s) {
  std::replace(s.begin(), s.end(), L'/', L'\\');
  Require(s.size() > 3 && s.size() <= 240 &&
      ((s[0] >= L'A' && s[0] <= L'Z') || (s[0] >= L'a' && s[0] <= L'z')) &&
      s[1] == L':' && s[2] == L'\\', "Update requires an ordinary local absolute path (at most 240 characters)");
  Relative(s.substr(3));
  return s;
}
inline std::wstring Image(HANDLE process = nullptr) {
  std::wstring s(32768, L'\0');
  DWORD n = static_cast<DWORD>(s.size());
  if (process) Require(QueryFullProcessImageNameW(process, 0, s.data(), &n) != FALSE, "Cannot identify exact update parent");
  else { n = GetModuleFileNameW(nullptr, s.data(), n); Require(n && n < s.size(), "Cannot locate running application"); }
  s.resize(n);
  return Absolute(s);
}
inline std::vector<BYTE> UserSid() {
  Handle token;
  HANDLE raw = nullptr;
  Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw) != FALSE, "Cannot inspect updater account");
  token.reset(raw);
  DWORD n = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &n);
  Require(n && n < 65536, "Invalid updater account token");
  std::vector<BYTE> bytes(n);
  Require(GetTokenInformation(token.get(), TokenUser, bytes.data(), n, &n) != FALSE, "Cannot read updater account");
  PSID sid = reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid;
  std::vector<BYTE> result(GetLengthSid(sid));
  Require(CopySid(static_cast<DWORD>(result.size()), result.data(), sid) != FALSE, "Cannot copy updater account");
  return result;
}
inline void Owned(HANDLE h) {
  PSID owner = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  DWORD error = GetSecurityInfo(h, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner, nullptr, nullptr, nullptr, &descriptor);
  const auto sid = UserSid();
  const bool equal = error == ERROR_SUCCESS && owner && EqualSid(owner, const_cast<BYTE*>(sid.data()));
  if (descriptor) LocalFree(descriptor);
  Require(equal, "Update staging must be owned by the current Windows account");
}
inline void Normal(HANDLE h, bool directory) {
  BY_HANDLE_FILE_INFORMATION info{};
  Require(GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, &info) != FALSE &&
      !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory &&
      (directory || info.nNumberOfLinks == 1), "Updater refuses links, reparse points, or non-regular files");
}
class Pins {
 public:
  void Directory(const std::wstring& path, bool owned = false) {
    Absolute(path);
    for (size_t end = 3;;) {
      end = path.find(L'\\', end);
      const std::wstring part = end == std::wstring::npos ? path : path.substr(0, end);
      auto found = directories_.find(part);
      if (found == directories_.end()) {
        Handle h(CreateFileW(part.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        Require(static_cast<bool>(h), "Cannot pin update directory; install may require the manual MSI");
        Normal(h.get(), true);
        found = directories_.emplace(part, std::move(h)).first;
      }
      if (owned && end == std::wstring::npos) Owned(found->second.get());
      if (end == std::wstring::npos) break;
      ++end;
    }
  }
 private:
  std::map<std::wstring, Handle, Less> directories_;
};
inline Handle ReadFilePinned(const std::wstring& path, bool owned) {
  Handle h(CreateFileW(path.c_str(), GENERIC_READ | READ_CONTROL, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
  Require(static_cast<bool>(h), "Cannot open staged update file exclusively for reading");
  Normal(h.get(), false);
  if (owned) Owned(h.get());
  return h;
}
inline uint64_t Size(HANDLE h) {
  LARGE_INTEGER n{};
  Require(GetFileSizeEx(h, &n) != FALSE && n.QuadPart >= 0, "Cannot read update file size");
  return static_cast<uint64_t>(n.QuadPart);
}
inline void Rewind(HANDLE h) {
  LARGE_INTEGER zero{};
  Require(SetFilePointerEx(h, zero, nullptr, FILE_BEGIN) != FALSE, "Cannot rewind update file");
}
inline std::array<BYTE, 32> Digest(HANDLE h) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  Require(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0, "SHA256 unavailable");
  struct Alg { BCRYPT_ALG_HANDLE h; ~Alg() { BCryptCloseAlgorithmProvider(h, 0); } } alg{algorithm};
  DWORD n = 0, received = 0;
  Require(BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&n), sizeof(n), &received, 0) >= 0 && n < 65536,
      "SHA256 configuration failed");
  std::vector<BYTE> object(n);
  BCRYPT_HASH_HANDLE hash = nullptr;
  Require(BCryptCreateHash(algorithm, &hash, object.data(), n, nullptr, 0, 0) >= 0, "SHA256 initialization failed");
  struct Hash { BCRYPT_HASH_HANDLE h; ~Hash() { BCryptDestroyHash(h); } } cleanup{hash};
  Rewind(h);
  std::array<BYTE, 65536> buffer{};
  for (;;) {
    DWORD read = 0;
    Require(ReadFile(h, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr) != FALSE, "Cannot hash update file");
    if (!read) break;
    Require(BCryptHashData(hash, buffer.data(), read, 0) >= 0, "Cannot hash update bytes");
  }
  std::array<BYTE, 32> result{};
  Require(BCryptFinishHash(hash, result.data(), static_cast<ULONG>(result.size()), 0) >= 0, "Cannot finish update SHA256");
  Rewind(h);
  return result;
}
inline std::array<BYTE, 32> Hex(const std::string& s) {
  Require(s.size() == 64, "Update digest must contain 64 hexadecimal characters");
  std::array<BYTE, 32> result{};
  auto nibble = [](char c) -> BYTE {
    if (c >= '0' && c <= '9') return static_cast<BYTE>(c - '0');
    if (c >= 'a' && c <= 'f') return static_cast<BYTE>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return static_cast<BYTE>(c - 'A' + 10);
    Fail("Invalid update SHA256");
  };
  for (size_t i = 0; i < result.size(); ++i) result[i] = static_cast<BYTE>((nibble(s[i * 2]) << 4) | nibble(s[i * 2 + 1]));
  return result;
}
struct File { std::wstring path; uint64_t size = 0; std::array<BYTE, 32> hash{}; };
struct Plan { std::wstring executable, payload, stage; std::vector<File> files; };
inline std::wstring Known(REFKNOWNFOLDERID id) {
  PWSTR raw = nullptr;
  Require(SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &raw)), "Cannot inspect protected user directories");
  std::wstring path(raw); CoTaskMemFree(raw); return path;
}
inline void ValidatePlan(const Plan& p) {
  Absolute(p.executable); Absolute(p.payload); Absolute(p.stage);
  Require(Same(Leaf(p.executable), L"triomi.exe"), "Only the running triomi.exe may be updated");
  const auto install = Parent(p.executable);
  Require(!Within(install, p.payload) && !Within(p.payload, install) && !Within(p.stage, install) &&
      !Within(install, p.stage), "Application and update staging must be separate");
  Require((Same(Leaf(p.payload), L"payload") || Leaf(p.payload).find(L"payload-") == 0) &&
      Same(Leaf(Parent(Parent(p.payload))), L"app-update") &&
      Leaf(Parent(p.payload)).find(L"bundle-") == 0 && Parent(p.stage) == Parent(p.payload) &&
      Leaf(p.stage).find(L"install-") == 0, "Unexpected update staging layout");
  const auto documents = Known(FOLDERID_Documents);
  const auto roaming = Known(FOLDERID_RoamingAppData);
  const auto local = Known(FOLDERID_LocalAppData);
  const auto profile = Known(FOLDERID_Profile);
  const auto support = roaming + L"\\io.github.hyperionhxh\\triomi";
  Require(!Same(install, documents) && !Same(install, roaming) && !Same(install, local) &&
      !Same(install, profile) && !Within(install, support) && !Within(support, install),
      "Updater will not write in user directory roots or Triomi profile data; use the manual MSI");
  Require(!p.files.empty() && p.files.size() <= kFileLimit, "Invalid update file count");
  uint64_t total = 0;
  std::set<std::wstring, Less> names;
  for (const auto& f : p.files) {
    Require(Relative(f.path) == f.path && names.insert(f.path).second, "Duplicate or unsafe update member");
    Require(f.size <= kMemberLimit && total <= kTotalLimit - f.size, "Update exceeds native size limits");
    total += f.size;
    Require((install + L"\\" + f.path).size() <= 240 && (p.payload + L"\\" + f.path).size() <= 240,
        "Expanded update path is too long");
  }
  Require(names.count(L"triomi.exe") && names.count(kHelperName), "Update must contain triomi.exe and its updater helper");
  for (const auto& name : names) {
    auto parent = Parent(name);
    while (parent != name && !parent.empty()) {
      Require(!names.count(parent), "Update file is also a parent directory");
      const auto next = Parent(parent);
      if (next == parent) break;
      parent = next;
    }
  }
}
inline std::vector<Handle> ValidatePayload(const Plan& p, Pins& pins) {
  pins.Directory(Parent(p.payload), true);
  pins.Directory(p.payload, true);
  pins.Directory(p.stage, true);
  pins.Directory(Parent(p.executable));
  std::vector<Handle> result;
  result.reserve(p.files.size());
  for (const auto& f : p.files) {
    const auto path = p.payload + L"\\" + f.path;
    auto parent = Parent(path);
    while (Within(parent, p.payload)) {
      pins.Directory(parent, true);
      if (Same(parent, p.payload)) break;
      parent = Parent(parent);
    }
    auto h = ReadFilePinned(path, true);
    Require(Size(h.get()) == f.size && Digest(h.get()) == f.hash, "Staged update content does not match its manifest");
    result.emplace_back(std::move(h));
  }
  return result;
}
inline void WriteAll(HANDLE h, const void* data, DWORD size) {
  const BYTE* p = static_cast<const BYTE*>(data);
  while (size) {
    DWORD written = 0;
    Require(WriteFile(h, p, size, &written, nullptr) && written, "Cannot write updater transaction data");
    size -= written; p += written;
  }
}
inline void Copy(HANDLE from, HANDLE to) {
  Rewind(from);
  std::array<BYTE, 65536> buffer{};
  for (;;) {
    DWORD n = 0;
    Require(ReadFile(from, buffer.data(), static_cast<DWORD>(buffer.size()), &n, nullptr) != FALSE, "Cannot read update payload");
    if (!n) break;
    WriteAll(to, buffer.data(), n);
  }
  Require(FlushFileBuffers(to) != FALSE, "Cannot flush updated file");
}
inline std::wstring Unique(const std::wstring& prefix) {
  std::array<BYTE, 16> random{};
  Require(BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0,
      "Cannot generate private update stage");
  const wchar_t* hex = L"0123456789abcdef";
  std::wstring name = prefix;
  for (BYTE b : random) { name += hex[b >> 4]; name += hex[b & 15]; }
  return name;
}
inline Handle NewFile(const std::wstring& path, DWORD access = GENERIC_READ | GENERIC_WRITE | DELETE) {
  Handle h(CreateFileW(path.c_str(), access, FILE_SHARE_READ, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Require(static_cast<bool>(h), "Install directory is not writable without elevation, or a file is locked; use the manual MSI");
  return h;
}
inline void DeleteOpen(HANDLE h) {
  FILE_DISPOSITION_INFO info{}; info.DeleteFile = TRUE;
  Require(SetFileInformationByHandle(h, FileDispositionInfo, &info, sizeof(info)) != FALSE, "Cannot remove transaction file during rollback");
}
inline void RenameOpen(HANDLE h, const std::wstring& destination) {
  const DWORD bytes = static_cast<DWORD>(destination.size() * sizeof(wchar_t));
  std::vector<BYTE> buffer(sizeof(FILE_RENAME_INFO) + bytes);
  auto* info = reinterpret_cast<FILE_RENAME_INFO*>(buffer.data());
  info->ReplaceIfExists = FALSE; info->RootDirectory = nullptr; info->FileNameLength = bytes;
  memcpy(info->FileName, destination.data(), bytes);
  Require(SetFileInformationByHandle(h, FileRenameInfo, info, static_cast<DWORD>(buffer.size())) != FALSE,
      "Cannot move install file transactionally (locked or not writable)");
}
inline void CheckWritable(const Plan& p) {
  const auto probe = Unique(Parent(p.executable) + L"\\.triomi-update-probe-");
  auto h = NewFile(probe);
  DeleteOpen(h.get());
}
// A compact fixed-width, little-endian protocol, never JSON or shell input.
inline std::vector<BYTE> Encode(const Plan& p) {
  std::vector<BYTE> bytes;
  auto integer = [&](uint64_t v, size_t n) { for (size_t i = 0; i < n; ++i) bytes.push_back(static_cast<BYTE>(v >> (8 * i))); };
  auto text = [&](const std::wstring& s) {
    integer(s.size(), 4);
    for (wchar_t c : s) integer(static_cast<uint16_t>(c), 2);
  };
  integer(0x31555054, 4); text(p.executable); text(p.payload); text(p.stage); integer(p.files.size(), 4);
  for (const auto& f : p.files) {
    text(f.path); integer(f.size, 8); bytes.insert(bytes.end(), f.hash.begin(), f.hash.end());
  }
  Require(bytes.size() <= kPlanLimit, "Update plan is too large");
  return bytes;
}
inline Plan Decode(HANDLE h) {
  Require(Size(h) <= kPlanLimit && Size(h) >= 16, "Invalid update plan length");
  std::vector<BYTE> bytes(static_cast<size_t>(Size(h)));
  Rewind(h);
  DWORD read = 0;
  Require(ReadFile(h, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr) && read == bytes.size(), "Cannot read update plan");
  size_t offset = 0;
  auto integer = [&](size_t n) -> uint64_t {
    Require(n <= bytes.size() - offset, "Truncated update plan");
    uint64_t value = 0;
    for (size_t i = 0; i < n; ++i) value |= static_cast<uint64_t>(bytes[offset++]) << (8 * i);
    return value;
  };
  auto text = [&]() {
    const auto n = integer(4);
    Require(n && n <= 240 && n * 2 <= bytes.size() - offset, "Invalid update plan path");
    std::wstring s;
    s.reserve(static_cast<size_t>(n));
    for (uint64_t i = 0; i < n; ++i) s += static_cast<wchar_t>(integer(2));
    return s;
  };
  Require(integer(4) == 0x31555054, "Unknown update plan version");
  Plan p; p.executable = text(); p.payload = text(); p.stage = text();
  const auto count = integer(4);
  Require(count && count <= kFileLimit, "Invalid update plan file count");
  p.files.reserve(static_cast<size_t>(count));
  for (uint64_t i = 0; i < count; ++i) {
    File f; f.path = text(); f.size = integer(8);
    for (auto& b : f.hash) b = static_cast<BYTE>(integer(1));
    p.files.push_back(std::move(f));
  }
  Require(offset == bytes.size(), "Trailing update plan bytes");
  ValidatePlan(p); return p;
}
inline std::wstring Quote(const std::wstring& s) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : s) {
    if (c == L'\\') { ++slashes; continue; }
    result.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\');
    result += c; slashes = 0;
  }
  result.append(slashes * 2, L'\\'); result += L'"'; return result;
}
inline Handle StartHelper(const Plan& p, HANDLE parent, const std::wstring& bundled_helper) {
  ValidatePlan(p);
  Pins pins;
  auto payload = ValidatePayload(p, pins);
  pins.Directory(Parent(bundled_helper));
  auto source = ReadFilePinned(bundled_helper, false);
  Require(Size(source.get()) > 0 && Size(source.get()) <= kMemberLimit,
      "Bundled Windows update helper exceeds native size limits");
  const auto helper = p.stage + L"\\" + kHelperName;
  {
    auto target = NewFile(helper);
    Copy(source.get(), target.get());
    Require(Digest(source.get()) == Digest(target.get()), "Staged helper copy failed integrity verification");
  }
  auto helper_pin = ReadFilePinned(helper, true);
  Require(Size(helper_pin.get()) == Size(source.get()) && Digest(helper_pin.get()) == Digest(source.get()),
      "Staged helper changed before launch");
  const auto plan_path = p.stage + L"\\plan.bin";
  auto plan = NewFile(plan_path);
  const auto bytes = Encode(p);
  WriteAll(plan.get(), bytes.data(), static_cast<DWORD>(bytes.size()));
  Require(FlushFileBuffers(plan.get()) != FALSE, "Cannot flush update plan");
  Rewind(plan.get());
  Handle child_plan, child_parent;
  HANDLE raw = nullptr;
  Require(DuplicateHandle(GetCurrentProcess(), plan.get(), GetCurrentProcess(), &raw, GENERIC_READ,
      TRUE, 0) != FALSE, "Cannot pass update plan");
  child_plan.reset(raw);
  Require(DuplicateHandle(GetCurrentProcess(), parent, GetCurrentProcess(), &raw,
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, TRUE, 0) != FALSE, "Cannot retain exact update parent");
  child_parent.reset(raw);
  SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
  HANDLE reader = nullptr, writer = nullptr;
  Require(CreatePipe(&reader, &writer, &security, 0) != FALSE, "Cannot create updater readiness channel");
  Handle pipe_read(reader), pipe_write(writer);
  Require(SetHandleInformation(pipe_read.get(), HANDLE_FLAG_INHERIT, 0) != FALSE, "Cannot secure updater readiness channel");
  SIZE_T n = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &n);
  std::vector<BYTE> buffer(n);
  auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(buffer.data());
  Require(InitializeProcThreadAttributeList(attributes, 1, 0, &n) != FALSE, "Cannot initialize helper handle isolation");
  struct Attributes { LPPROC_THREAD_ATTRIBUTE_LIST p; ~Attributes() { DeleteProcThreadAttributeList(p); } } cleanup{attributes};
  HANDLE inherited[] = {child_plan.get(), child_parent.get(), pipe_write.get()};
  Require(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited, sizeof(inherited), nullptr, nullptr) != FALSE, "Cannot isolate inherited updater handles");
  auto number = [](HANDLE h) { return std::to_wstring(reinterpret_cast<uintptr_t>(h)); };
  std::wstring command = Quote(helper) + L" --apply " + number(child_plan.get()) + L" " +
      number(child_parent.get()) + L" " + number(pipe_write.get());
  STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = attributes;
  PROCESS_INFORMATION process{};
  Require(CreateProcessW(helper.c_str(), command.data(), nullptr, nullptr, TRUE,
      EXTENDED_STARTUPINFO_PRESENT | DETACHED_PROCESS | CREATE_UNICODE_ENVIRONMENT,
      nullptr, p.stage.c_str(), &startup.StartupInfo, &process) != FALSE,
      "Cannot launch Windows update helper; use the manual MSI");
  Handle child(process.hProcess), thread(process.hThread);
  struct UnreadyChild {
    HANDLE process;
    bool active = true;
    ~UnreadyChild() {
      if (active) { TerminateProcess(process, ERROR_CANCELLED); WaitForSingleObject(process, 5000); }
    }
  } unready{child.get()};
  pipe_write.reset(); child_plan.reset(); child_parent.reset();
  const ULONGLONG deadline = GetTickCount64() + 10000;
  std::string response;
  while (GetTickCount64() < deadline) {
    DWORD available = 0;
    if (!PeekNamedPipe(pipe_read.get(), nullptr, 0, nullptr, &available, nullptr)) break;
    if (available) {
      char data[512]; DWORD count = 0;
      Require(ReadFile(pipe_read.get(), data, std::min<DWORD>(available, sizeof(data)), &count, nullptr) != FALSE,
          "Cannot read updater readiness");
      response.append(data, count);
      if (response.find('\n') != std::string::npos) break;
      if (response.size() > 4096) break;
    }
    if (WaitForSingleObject(child.get(), 0) != WAIT_TIMEOUT) break;
    Sleep(20);
  }
  if (response != "READY\n") {
    // The helper cannot write until this exact parent exits. Stop an unready
    // helper before allowing any later app shutdown to become authorization.
    Fail(response.rfind("ERROR:", 0) == 0 ? response.c_str() + 6 : "Windows update helper did not become ready within 10 seconds");
  }
  unready.active = false;
  return child;
}
}  // namespace triomi_update
#endif  // RUNNER_WINDOWS_UPDATE_COMMON_H_
