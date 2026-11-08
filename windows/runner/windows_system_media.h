#ifndef RUNNER_WINDOWS_SYSTEM_MEDIA_H_
#define RUNNER_WINDOWS_SYSTEM_MEDIA_H_

#include <windows.h>
#include <flutter/binary_messenger.h>

// Main visible engine only, on its COM STA/UI thread. The module owns the
// triomi/windows-media channel; it must not replace triomi/platform's handler.
// CMake: add windows_system_media.cpp and link windowsapp + runtimeobject.
// Uses the public Windows 10 SDK ISystemMediaTransportControlsInterop::GetForWindow
// for exactly this HWND (never GetForCurrentView or another process's session).
void InitializeWindowsSystemMedia(flutter::BinaryMessenger* messenger, HWND owner);

// Call before Flutter's top-level window proc. Consumes only this module's
// registered button message, dispatching the command on the engine/UI thread.
bool WindowsSystemMediaOnMessage(HWND owner, UINT message, WPARAM wparam,
                                LPARAM lparam);

// Before the engine/HWND is destroyed and before COM is uninitialized.
void CloseWindowsSystemMedia();

#endif  // RUNNER_WINDOWS_SYSTEM_MEDIA_H_
