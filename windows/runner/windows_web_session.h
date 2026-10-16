#pragma once

#include <windows.h>
#include <flutter/binary_messenger.h>

// Must be registered only in the foreground application engine.
void RegisterWindowsWebSession(flutter::BinaryMessenger* messenger, HWND owner);
// Called synchronously on WM_ACTIVATEAPP before Flutter paints a locked frame.
void WindowsWebSessionOnActivate(bool active);
void WindowsWebSessionOnResize();
void CloseWindowsWebSessions();
