#include "app_update.h"
#include <windows.h>
#include <stdexcept>
#include <string>
#include <vector>

static flutter::EncodableMap InspectExecutable(const wchar_t* path) {
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(path, &ignored);
  if (!size) throw std::runtime_error("Executable version unavailable");
  std::vector<BYTE> data(size);
  if (!GetFileVersionInfoW(path, 0, size, data.data())) throw std::runtime_error("Executable version unavailable");
  VS_FIXEDFILEINFO* info = nullptr;
  UINT info_size = 0;
  if (!VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&info), &info_size) ||
      info_size < sizeof(VS_FIXEDFILEINFO) || info->dwSignature != 0xfeef04bd)
    throw std::runtime_error("Executable version invalid");
  wchar_t* product = nullptr;
  UINT product_size = 0;
  if (!VerQueryValueW(data.data(), L"\\StringFileInfo\\040904e4\\ProductName",
          reinterpret_cast<void**>(&product), &product_size) || !product ||
      std::wstring(product) != L"triomi") throw std::runtime_error("Wrong desktop product");
  const std::string version = std::to_string(HIWORD(info->dwFileVersionMS)) + "." +
      std::to_string(LOWORD(info->dwFileVersionMS)) + "." + std::to_string(HIWORD(info->dwFileVersionLS));
  const int utf8_size = WideCharToMultiByte(CP_UTF8, 0, path, -1, nullptr, 0, nullptr, nullptr);
  if (!utf8_size) throw std::runtime_error("Executable path invalid");
  std::string utf8(utf8_size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8.data(), utf8_size, nullptr, nullptr);
  utf8.pop_back();
  using flutter::EncodableValue;
  return {{EncodableValue("packageName"), EncodableValue("io.github.hyperionhxh.triomi")},
          {EncodableValue("platform"), EncodableValue("windows")},
          {EncodableValue("version"), EncodableValue(version)},
          {EncodableValue("versionCode"), EncodableValue(static_cast<int64_t>(LOWORD(info->dwFileVersionLS)))},
          {EncodableValue("path"), EncodableValue(utf8)}};
}

flutter::EncodableMap CurrentAppUpdateInfo() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) throw std::runtime_error("Cannot inspect running executable");
  return InspectExecutable(path.data());
}

flutter::EncodableMap AppUpdateExecutableInfo(const std::string& path) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.c_str(), -1, nullptr, 0);
  if (!length) throw std::runtime_error("Invalid candidate path");
  std::vector<wchar_t> wide(length);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.c_str(), -1, wide.data(), length);
  const DWORD attributes = GetFileAttributesW(wide.data());
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
    throw std::runtime_error("Candidate must be a regular file");
  return InspectExecutable(wide.data());
}
