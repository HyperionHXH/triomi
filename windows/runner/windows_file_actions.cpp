#include "windows_file_actions.h"

#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
constexpr LONGLONG kFontLimit = 64LL * 1024 * 1024;
constexpr LONGLONG kImageLimit = 64LL * 1024 * 1024;

std::string Utf8(const std::wstring& value) {
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!size) return {};
  std::string text(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), text.data(), size, nullptr, nullptr);
  return text;
}

const EncodableValue* Argument(const EncodableValue* args, const char* key) {
  const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
  if (!map) return nullptr;
  const auto it = map->find(EncodableValue(key));
  return it == map->end() ? nullptr : &it->second;
}

HRESULT Pick(HWND owner, bool directory, const COMDLG_FILTERSPEC* filters,
             UINT count, std::wstring* path) {
  ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(hr)) hr = dialog->GetOptions(&options);
  if (SUCCEEDED(hr)) hr = dialog->SetOptions(options | FOS_FORCEFILESYSTEM |
      FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR |
      (directory ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST));
  if (SUCCEEDED(hr) && !directory) hr = dialog->SetFileTypes(count, filters);
  if (SUCCEEDED(hr)) hr = dialog->Show(owner);
  ComPtr<IShellItem> item;
  if (SUCCEEDED(hr)) hr = dialog->GetResult(&item);
  PWSTR raw = nullptr;
  if (SUCCEEDED(hr)) hr = item->GetDisplayName(SIGDN_FILESYSPATH, &raw);
  if (SUCCEEDED(hr) && raw) *path = raw;
  else if (SUCCEEDED(hr)) hr = E_FAIL;
  CoTaskMemFree(raw);
  return hr;
}

// Size is checked on the opened handle, and reads cannot exceed that bound.
bool ReadSelected(const std::wstring& path, LONGLONG limit,
                  std::vector<uint8_t>* bytes, bool read) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
      nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  bool ok = GetFileType(file) == FILE_TYPE_DISK &&
      GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= limit;
  if (ok && read) {
    bytes->resize(static_cast<size_t>(size.QuadPart));
    DWORD actual = 0;
    ok = ReadFile(file, bytes->data(), static_cast<DWORD>(bytes->size()),
                  &actual, nullptr) && actual == bytes->size();
  }
  CloseHandle(file);
  return ok;
}

std::wstring Extension(const std::wstring& path) {
  auto ext = std::filesystem::path(path).extension().wstring();
  std::transform(ext.begin(), ext.end(), ext.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  return ext;
}

const char* ImageMime(const std::wstring& ext) {
  if (ext == L".jpg" || ext == L".jpeg") return "image/jpeg";
  if (ext == L".png") return "image/png";
  if (ext == L".webp") return "image/webp";
  if (ext == L".gif") return "image/gif";
  if (ext == L".avif") return "image/avif";
  if (ext == L".bmp") return "image/bmp";
  return nullptr;
}

// Ignore any requested directories, drive/ADS syntax or reserved device names.
std::wstring SafeStem(const std::string* requested) {
  std::wstring stem = L"triomi-image";
  if (requested && !requested->empty()) {
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        requested->data(), static_cast<int>(requested->size()), nullptr, 0);
    if (count > 0 && count <= 240) {
      std::wstring name(count, L'\0');
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, requested->data(),
          static_cast<int>(requested->size()), name.data(), count);
      name = std::filesystem::path(name).filename().stem().wstring();
      for (auto& c : name) {
        if (c < 32 || std::wstring(L"<>:\"/\\|?*").find(c) != std::wstring::npos)
          c = L'_';
      }
      while (!name.empty() && (name.back() == L'.' || name.back() == L' '))
        name.pop_back();
      if (!name.empty()) stem = L"triomi-" + name.substr(0, 120);
    }
  }
  return stem;
}

std::wstring ImageExtension(const std::vector<uint8_t>& bytes) {
  if (bytes.size() >= 8 && bytes[0] == 0x89 && bytes[1] == 'P' &&
      bytes[2] == 'N' && bytes[3] == 'G') return L".png";
  if (bytes.size() >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 &&
      bytes[2] == 0xff) return L".jpg";
  if (bytes.size() >= 6 && bytes[0] == 'G' && bytes[1] == 'I' &&
      bytes[2] == 'F') return L".gif";
  if (bytes.size() >= 12 && bytes[0] == 'R' && bytes[1] == 'I' &&
      bytes[2] == 'F' && bytes[3] == 'F' && bytes[8] == 'W' &&
      bytes[9] == 'E' && bytes[10] == 'B' && bytes[11] == 'P') return L".webp";
  if (bytes.size() >= 12 && bytes[4] == 'f' && bytes[5] == 't' &&
      bytes[6] == 'y' && bytes[7] == 'p' && bytes[8] == 'a' &&
      bytes[9] == 'v' && bytes[10] == 'i' &&
      (bytes[11] == 'f' || bytes[11] == 's')) return L".avif";
  if (bytes.size() >= 2 && bytes[0] == 'B' && bytes[1] == 'M') return L".bmp";
  return {};
}

void SaveImage(const EncodableValue* args,
               flutter::MethodResult<EncodableValue>* result) {
  const auto* value = Argument(args, "bytes");
  const auto* bytes = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
  if (!bytes || bytes->empty() || bytes->size() > static_cast<size_t>(kImageLimit)) {
    result->Error("invalid_args", "Image must contain 1 byte to 64 MiB");
    return;
  }
  const auto extension = ImageExtension(*bytes);
  if (extension.empty()) {
    result->Error("invalid_args", "Unsupported image format");
    return;
  }
  PWSTR pictures = nullptr;
  const HRESULT hr = SHGetKnownFolderPath(FOLDERID_Pictures, 0, nullptr, &pictures);
  if (FAILED(hr) || !pictures) {
    CoTaskMemFree(pictures);
    result->Error("save_failed", "Pictures folder is unavailable");
    return;
  }
  const auto directory = std::filesystem::path(pictures) / L"Triomi";
  CoTaskMemFree(pictures);
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) {
    result->Error("save_failed", "Cannot create Pictures/Triomi");
    return;
  }
  const auto* name = Argument(args, "fileName");
  const auto stem = SafeStem(name ? std::get_if<std::string>(name) : nullptr);
  for (unsigned i = 0; i < 10000; ++i) {
    const auto suffix = i ? L"-" + std::to_wstring(i) : L"";
    const auto path = directory / (stem + suffix + extension);
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      if (GetLastError() == ERROR_FILE_EXISTS || GetLastError() == ERROR_ALREADY_EXISTS)
        continue;
      break;
    }
    DWORD actual = 0;
    const bool ok = WriteFile(file, bytes->data(), static_cast<DWORD>(bytes->size()),
        &actual, nullptr) && actual == bytes->size() && FlushFileBuffers(file);
    CloseHandle(file);
    if (!ok) {
      DeleteFileW(path.c_str());
      break;
    }
    result->Success(EncodableValue(Utf8(path.wstring())));
    return;
  }
  result->Error("save_failed", "Cannot write image to Pictures/Triomi");
}
}  // namespace

bool HandleWindowsFileAction(HWND owner, const std::string& method,
    const EncodableValue* args, flutter::MethodResult<EncodableValue>* result) {
  const bool font = method == "pickFontFile";
  const bool image = method == "pickImage";
  const bool comic = method == "pickLocalComic";
  if (!font && !image && !comic && method != "pickDirectory" &&
      method != "saveImageToGallery") return false;
  try {
    if (method == "saveImageToGallery") {
      SaveImage(args, result);
      return true;
    }
    const auto* directoryArg = Argument(args, "directory");
    const auto* directoryValue = directoryArg ? std::get_if<bool>(directoryArg) : nullptr;
    const bool directory = method == "pickDirectory" ||
        (comic && directoryValue && *directoryValue);
    const COMDLG_FILTERSPEC fontFilter[] = {{L"Fonts (TTF / OTF)", L"*.ttf;*.otf"}};
    const COMDLG_FILTERSPEC imageFilter[] = {{L"Images", L"*.png;*.jpg;*.jpeg;*.webp;*.gif;*.avif;*.bmp"}};
    const COMDLG_FILTERSPEC comicFilter[] = {{L"Comic archives or images", L"*.zip;*.cbz;*.png;*.jpg;*.jpeg;*.webp;*.gif;*.avif"}};
    std::wstring path;
    const HRESULT hr = Pick(owner, directory, font ? fontFilter :
        (image ? imageFilter : comicFilter), 1, &path);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      result->Success();
      return true;
    }
    if (FAILED(hr)) {
      result->Error("picker_failed", "Cannot read Windows dialog selection");
      return true;
    }
    if (font || image) {
      const auto ext = Extension(path);
      const char* mime = image ? ImageMime(ext) : nullptr;
      std::vector<uint8_t> bytes;
      if ((font && ext != L".ttf" && ext != L".otf") || (image && !mime) ||
          !ReadSelected(path, font ? kFontLimit : kImageLimit, &bytes, image)) {
        result->Error("read_failed", "Select a supported, readable file of 1 byte to 64 MiB");
        return true;
      }
      if (image) {
        mime = ImageMime(ImageExtension(bytes));
        if (!mime) {
          result->Error("read_failed", "Selected file is not a supported image");
          return true;
        }
        result->Success(EncodableValue(EncodableMap{
            {EncodableValue("bytes"), EncodableValue(std::move(bytes))},
            {EncodableValue("name"), EncodableValue(Utf8(std::filesystem::path(path).filename().wstring()))},
            {EncodableValue("mime"), EncodableValue(mime)}}));
        return true;
      }
    }
    if (comic) {
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("paths"), EncodableValue(flutter::EncodableList{EncodableValue(Utf8(path))})}}));
    } else {
      result->Success(EncodableValue(Utf8(path)));
    }
  } catch (const std::exception& error) {
    result->Error("file_action_failed", error.what());
  }
  return true;
}
