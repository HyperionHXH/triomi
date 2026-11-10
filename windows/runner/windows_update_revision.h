#ifndef RUNNER_WINDOWS_UPDATE_REVISION_H_
#define RUNNER_WINDOWS_UPDATE_REVISION_H_

#include "windows_update_common.h"
#include <winver.h>

namespace triomi_update {
struct InstalledRevision {
  std::wstring version;
  uint64_t revision = 0;
};
inline uint64_t DecimalRevision(const std::wstring& text) {
  Require(!text.empty() && text.size() <= 20, "Invalid Windows servicing revision");
  uint64_t value = 0;
  for (wchar_t c : text) {
    Require(c >= L'0' && c <= L'9', "Windows servicing revision must be decimal");
    const auto digit = static_cast<uint64_t>(c - L'0');
    Require(value <= (UINT64_MAX - digit) / 10, "Windows servicing revision is out of range");
    value = value * 10 + digit;
  }
  return value;
}
inline InstalledRevision ReadInstalledRevision(const std::wstring& executable) {
  auto pin = ReadFilePinned(executable, false);
  Require(Size(pin.get()) <= kMemberLimit, "Installed executable exceeds native size limits");
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(executable.c_str(), &ignored);
  Require(size && size <= 1024 * 1024, "Triomi executable version resource is missing or too large");
  std::vector<BYTE> bytes(size);
  Require(GetFileVersionInfoW(executable.c_str(), 0, size, bytes.data()) != FALSE,
      "Cannot read Triomi executable version resource");
  VS_FIXEDFILEINFO* info = nullptr;
  UINT length = 0;
  Require(VerQueryValueW(bytes.data(), L"\\", reinterpret_cast<void**>(&info), &length) &&
      length >= sizeof(VS_FIXEDFILEINFO) && info && info->dwSignature == 0xfeef04bd && info->dwFileType == VFT_APP,
      "Invalid Triomi executable version resource");
  wchar_t* product = nullptr;
  length = 0;
  Require(VerQueryValueW(bytes.data(), L"\\StringFileInfo\\040904e4\\ProductName",
      reinterpret_cast<void**>(&product), &length) && product && length == 7 &&
      std::wstring(product, 7) == std::wstring(L"triomi\0", 7), "Installed executable is not the Triomi product");
  InstalledRevision result;
  result.version = std::to_wstring(HIWORD(info->dwFileVersionMS)) + L"." +
      std::to_wstring(LOWORD(info->dwFileVersionMS)) + L"." +
      std::to_wstring(HIWORD(info->dwFileVersionLS)) + L"+" +
      std::to_wstring(LOWORD(info->dwFileVersionLS));
  wchar_t* revision = nullptr;
  length = 0;
  if (VerQueryValueW(bytes.data(), L"\\StringFileInfo\\040904e4\\TriomiWindowsRevision",
      reinterpret_cast<void**>(&revision), &length)) {
    Require(revision && length >= 2 && length <= 21 && revision[length - 1] == L'\0',
        "Invalid Triomi Windows revision resource");
    result.revision = DecimalRevision(std::wstring(revision, length - 1));
  }
  // Old genuine Triomi executables did not carry this string: revision zero.
  return result;
}
class RegistryKey {
 public:
  ~RegistryKey() { if (key_) RegCloseKey(key_); }
  HKEY* put() { return &key_; }
  HKEY get() const { return key_; }
 private:
  HKEY key_ = nullptr;
};
inline void RecordInstalledRevision(const std::wstring& executable) {
  const auto installed = ReadInstalledRevision(executable);
  const auto path = L"Software\\Triomi\\Installer\\Versions\\" + installed.version;
  RegistryKey key;
  Require(RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
      KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, key.put(), nullptr) == ERROR_SUCCESS,
      "Application files were installed, but Windows servicing protection could not be saved");
  std::array<wchar_t, 32> existing{};
  DWORD type = 0, bytes = static_cast<DWORD>(sizeof(existing));
  const LSTATUS status = RegQueryValueExW(key.get(), L"InstalledWindowsRevision", nullptr,
      &type, reinterpret_cast<BYTE*>(existing.data()), &bytes);
  uint64_t previous = 0;
  if (status != ERROR_FILE_NOT_FOUND) {
    Require(status == ERROR_SUCCESS && type == REG_SZ && bytes >= 2 * sizeof(wchar_t) &&
        bytes % sizeof(wchar_t) == 0 && bytes <= sizeof(existing) &&
        existing[bytes / sizeof(wchar_t) - 1] == L'\0',
        "Existing Windows servicing protection is invalid; it was not overwritten");
    previous = DecimalRevision(std::wstring(existing.data(), bytes / sizeof(wchar_t) - 1));
    if (previous >= installed.revision) return;
  }
  const auto revision = std::to_wstring(installed.revision);
  Require(RegSetValueExW(key.get(), L"InstalledWindowsRevision", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(revision.c_str()), static_cast<DWORD>((revision.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS,
      "Application files were installed, but Windows servicing protection could not be saved");
}
}  // namespace triomi_update
#endif  // RUNNER_WINDOWS_UPDATE_REVISION_H_
