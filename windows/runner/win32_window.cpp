#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

bool Win32Window::RestoreWindowedState(std::string* failure_stage, DWORD* error) {
  if (!windowed_state_saved_) return true;
  fullscreen_ = false;
  fullscreen_transition_ = true;
  const auto fail = [&](const char* stage) {
    *failure_stage = stage;
    *error = GetLastError();
    fullscreen_transition_ = false;
    return false;
  };
  SetLastError(ERROR_SUCCESS);
  if (!SetWindowLongPtr(window_handle_, GWL_STYLE,
                        windowed_style_ & ~(WS_MAXIMIZE | WS_MINIMIZE)) &&
      GetLastError() != ERROR_SUCCESS) {
    return fail("restore_style");
  }
  SetLastError(ERROR_SUCCESS);
  if (!SetWindowLongPtr(window_handle_, GWL_EXSTYLE, windowed_ex_style_) &&
      GetLastError() != ERROR_SUCCESS) {
    return fail("restore_extended_style");
  }
  if (!SetWindowPlacement(window_handle_, &windowed_placement_)) {
    return fail("restore_placement");
  }
  if (!SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                        SWP_FRAMECHANGED)) {
    return fail("restore_frame");
  }
  windowed_state_saved_ = false;
  fullscreen_transition_ = false;
  return true;
}

bool Win32Window::SetFullscreen(bool enabled, std::string* failure_stage,
                                DWORD* error) {
  failure_stage->clear();
  *error = ERROR_SUCCESS;
  if (!window_handle_ || !IsWindow(window_handle_)) {
    *failure_stage = "window_unavailable";
    *error = ERROR_INVALID_WINDOW_HANDLE;
    return false;
  }
  if (enabled && fullscreen_) return true;
  // Also finishes a rollback that previously failed, without losing its snapshot.
  if (!RestoreWindowedState(failure_stage, error)) return false;
  if (!enabled) return true;

  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  const HMONITOR monitor =
      MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfo(monitor, &monitor_info)) {
    *failure_stage = "monitor_bounds";
    *error = GetLastError();
    return false;
  }
  windowed_placement_.length = sizeof(windowed_placement_);
  if (!GetWindowPlacement(window_handle_, &windowed_placement_)) {
    *failure_stage = "save_placement";
    *error = GetLastError();
    return false;
  }
  SetLastError(ERROR_SUCCESS);
  windowed_style_ = GetWindowLongPtr(window_handle_, GWL_STYLE);
  if (!windowed_style_ && GetLastError() != ERROR_SUCCESS) {
    *failure_stage = "save_style";
    *error = GetLastError();
    return false;
  }
  SetLastError(ERROR_SUCCESS);
  windowed_ex_style_ = GetWindowLongPtr(window_handle_, GWL_EXSTYLE);
  if (!windowed_ex_style_ && GetLastError() != ERROR_SUCCESS) {
    *failure_stage = "save_extended_style";
    *error = GetLastError();
    return false;
  }
  windowed_state_saved_ = true;
  fullscreen_transition_ = true;
  const auto fail = [&](const char* stage) {
    const DWORD original_error = GetLastError();
    std::string rollback_stage;
    DWORD rollback_error = ERROR_SUCCESS;
    const bool restored = RestoreWindowedState(&rollback_stage, &rollback_error);
    *failure_stage = stage;
    if (!restored) *failure_stage += "/rollback_" + rollback_stage;
    *error = original_error;
    return false;
  };
  // Clear native maximization before applying physical monitor bounds. The
  // original WINDOWPLACEMENT remains untouched for restoring a maximized window.
  if (IsZoomed(window_handle_) || IsIconic(window_handle_)) {
    ShowWindow(window_handle_, SW_RESTORE);
  }
  SetLastError(ERROR_SUCCESS);
  const LONG_PTR fullscreen_style =
      (windowed_style_ & ~(WS_OVERLAPPEDWINDOW | WS_MAXIMIZE | WS_MINIMIZE)) |
      WS_POPUP;
  if (!SetWindowLongPtr(window_handle_, GWL_STYLE, fullscreen_style) &&
      GetLastError() != ERROR_SUCCESS) {
    return fail("enter_style");
  }
  SetLastError(ERROR_SUCCESS);
  if (!SetWindowLongPtr(window_handle_, GWL_EXSTYLE,
                        windowed_ex_style_ & ~(WS_EX_WINDOWEDGE |
                            WS_EX_CLIENTEDGE | WS_EX_DLGMODALFRAME |
                            WS_EX_STATICEDGE)) &&
      GetLastError() != ERROR_SUCCESS) {
    return fail("enter_extended_style");
  }
  // rcMonitor, not rcWork: the active borderless window covers the taskbar too.
  // Do not make it permanently topmost; Alt+Tab must keep working normally.
  const RECT& bounds = monitor_info.rcMonitor;
  if (!SetWindowPos(window_handle_, HWND_TOP, bounds.left, bounds.top,
                    bounds.right - bounds.left, bounds.bottom - bounds.top,
                    SWP_FRAMECHANGED | SWP_NOOWNERZORDER)) {
    return fail("enter_monitor_bounds");
  }
  RECT actual = {};
  if (!GetWindowRect(window_handle_, &actual)) return fail("verify_bounds");
  if (!EqualRect(&actual, &bounds)) {
    SetLastError(ERROR_INVALID_STATE);
    return fail("verify_bounds");
  }
  fullscreen_ = true;
  fullscreen_transition_ = false;
  return true;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED: {
      if (fullscreen_transition_) return 0;
      if (!fullscreen_) {
        if (message == WM_DISPLAYCHANGE) break;
        auto suggested = reinterpret_cast<RECT*>(lparam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
      }
      // A different-DPI monitor's suggested rectangle is a windowed size.
      // Keep fullscreen pinned to the actual new monitor, including negative
      // virtual-screen coordinates and display-removal fallback.
      const HMONITOR monitor = message == WM_DPICHANGED
          ? MonitorFromRect(reinterpret_cast<RECT*>(lparam), MONITOR_DEFAULTTONEAREST)
          : MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      MONITORINFO info = {};
      info.cbSize = sizeof(info);
      if (GetMonitorInfo(monitor, &info)) {
        const RECT& bounds = info.rcMonitor;
        SetWindowPos(hwnd, nullptr, bounds.left, bounds.top,
                     bounds.right - bounds.left, bounds.bottom - bounds.top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      }
      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  if (window_handle_ && windowed_state_saved_) {
    std::string stage;
    DWORD error = ERROR_SUCCESS;
    if (!RestoreWindowedState(&stage, &error)) {
      OutputDebugStringA(("triomi fullscreen disposal restore failed: " + stage +
                          " (" + std::to_string(error) + ")\n").c_str());
    }
  }
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content, bool take_focus) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  if (take_focus) SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
