#include "flutter_window.h"

#include <optional>
#include <exception>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "windows_backup.h"
#include "app_update.h"
#include "windows_web_session.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool worker,
                             bool backup_worker)
    : project_(project), worker_(worker), backup_worker_(backup_worker) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // The backup needs only the real Dart/FFI path_provider plugin (registered by
  // Flutter's Dart registrant). Do not initialize JS, credentials or MediaKit
  // native plugins in this metadata-only process.
  if (!worker_ && !backup_worker_) RegisterPlugins(flutter_controller_->engine());
  if (!worker_ && !backup_worker_) {
    RegisterWindowsWebSession(flutter_controller_->engine()->messenger(), GetHandle());
  }
  if (!worker_) {
    platform_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        flutter_controller_->engine()->messenger(), "triomi/platform",
        &flutter::StandardMethodCodec::GetInstance());
    platform_channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          if (call.method_name() == "completeLocalBackup" && backup_worker_) {
            const auto* code = call.arguments() == nullptr ? nullptr :
                std::get_if<int32_t>(call.arguments());
            if (!code || (*code != 0 && *code != 1)) {
              result->Error("invalid_exit", "backup exit code is required");
              return;
            }
            result->Success();
            // Return an observable Task Scheduler result, not Android's done
            // channel. Engine/plugin teardown follows after the message loop.
            ::PostQuitMessage(*code);
            return;
          }
          if (call.method_name() == "scheduleLocalBackups" && !backup_worker_) {
            const auto* enabled = call.arguments() == nullptr ? nullptr :
                std::get_if<bool>(call.arguments());
            if (!enabled) {
              result->Error("invalid_schedule", "enabled flag is required");
              return;
            }
            const HRESULT status = SetLocalBackupSchedule(*enabled);
            if (FAILED(status)) {
              result->Error("schedule_failed",
                  "Windows Task Scheduler could not update the local backup task");
              return;
            }
            result->Success(flutter::EncodableValue(true));
            return;
          }
          if (call.method_name() == "currentAppUpdateInfo" && !backup_worker_) {
            try {
              result->Success(flutter::EncodableValue(CurrentAppUpdateInfo()));
            } catch (const std::exception&) {
              result->Error("version_unavailable", "cannot inspect running executable version");
            }
            return;
          }
          if (call.method_name() == "inspectAppUpdateInfo" && !backup_worker_) {
            const auto* args = call.arguments() == nullptr ? nullptr :
                std::get_if<flutter::EncodableMap>(call.arguments());
            if (!args) { result->Error("invalid_path", "candidate path is required"); return; }
            const auto entry = args->find(flutter::EncodableValue("path"));
            const auto* path = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
            if (!path || path->empty()) { result->Error("invalid_path", "candidate path is required"); return; }
            try {
              result->Success(flutter::EncodableValue(AppUpdateExecutableInfo(*path)));
            } catch (const std::exception&) {
              result->Error("version_unavailable", "cannot inspect candidate executable version");
            }
            return;
          }
          if (call.method_name() != "availableDiskBytes") {
            result->NotImplemented();
            return;
          }
          const auto* args = call.arguments() == nullptr ? nullptr :
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Error("invalid_path", "destination path is required"); return; }
          const auto entry = args->find(flutter::EncodableValue("path"));
          const auto* path = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
          if (!path || path->empty()) { result->Error("invalid_path", "destination path is required"); return; }
          const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
              path->data(), static_cast<int>(path->size()), nullptr, 0);
          if (!length) { result->Error("invalid_path", "destination path encoding is invalid"); return; }
          std::wstring wide(length, L'\0');
          MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(),
              static_cast<int>(path->size()), wide.data(), length);
          ULARGE_INTEGER available;
          if (!GetDiskFreeSpaceExW(wide.c_str(), &available, nullptr, nullptr)) {
            result->Error("disk_unavailable", "cannot inspect destination disk");
            return;
          }
          result->Success(flutter::EncodableValue(static_cast<int64_t>(available.QuadPart)));
        });
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow(), !backup_worker_);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!worker_ && !backup_worker_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  CloseWindowsWebSessions();
  platform_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_SIZE) WindowsWebSessionOnResize();
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
