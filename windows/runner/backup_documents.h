#pragma once

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <memory>
#include <string>

inline void RegisterBackupDocuments(flutter::BinaryMessenger* messenger, HWND owner) {
  // The channel outlives its handler with the engine, like other runner hosts.
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "triomi/backupDocuments", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([owner](const auto& call, auto result) {
    const bool directory = call.method_name() == "pickDirectory";
    if (!directory && call.method_name() != "pickBackup") { result->NotImplemented(); return; }
    Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&dialog));
    if (FAILED(hr)) { result->Error("picker_failed", "Cannot open Windows file dialog"); return; }
    FILEOPENDIALOGOPTIONS options;
    hr = dialog->GetOptions(&options);
    if (SUCCEEDED(hr)) hr = dialog->SetOptions(options | FOS_FORCEFILESYSTEM |
        FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR | (directory ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST));
    if (!directory && SUCCEEDED(hr)) {
      const COMDLG_FILTERSPEC filter[] = {{L"Triomi backup ZIP", L"*.zip"}};
      hr = dialog->SetFileTypes(1, filter);
    }
    if (SUCCEEDED(hr)) hr = dialog->Show(owner);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(); return; }
    Microsoft::WRL::ComPtr<IShellItem> item;
    if (SUCCEEDED(hr)) hr = dialog->GetResult(&item);
    PWSTR path = nullptr;
    if (SUCCEEDED(hr)) hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
    if (FAILED(hr) || !path) { result->Error("picker_failed", "Cannot read selected path"); return; }
    const int size = WideCharToMultiByte(CP_UTF8, 0, path, -1, nullptr, 0, nullptr, nullptr);
    std::string value(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, path, -1, value.data(), size, nullptr, nullptr);
    CoTaskMemFree(path);
    value.pop_back();
    if (directory) result->Success(flutter::EncodableValue(value));
    else result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("path"), flutter::EncodableValue(value)},
      {flutter::EncodableValue("uri"), flutter::EncodableValue(value)}}));
  });
}
