#pragma once

#include <windows.h>
#include <flutter/binary_messenger.h>

// Must be registered only in the foreground application engine.
void RegisterWindowsWebSession(flutter::BinaryMessenger* messenger, HWND owner);
void WindowsWebSessionOnResize();
void CloseWindowsWebSessions();
