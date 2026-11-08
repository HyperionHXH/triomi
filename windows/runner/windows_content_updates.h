#ifndef RUNNER_WINDOWS_CONTENT_UPDATES_H_
#define RUNNER_WINDOWS_CONTENT_UPDATES_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>

// Call on the COM-initialized platform thread in both foreground and hidden
// content-worker engines. The caller owns the profile mutex before engine start.
// Also registers triomi/content-notifications. Notification futures settle only
// after presentation/completion callbacks (or explicit failure), so the worker
// must keep pumping messages while Dart is awaiting them; no shutdown sleep.
void InitializeWindowsContentUpdates(HWND owner, flutter::BinaryMessenger* messenger);
bool HandleWindowsContentUpdates(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    flutter::MethodResult<flutter::EncodableValue>* result);
void WindowsContentUpdatesOnMessage(UINT message, WPARAM wparam, LPARAM lparam);
void CloseWindowsContentUpdates();

#endif  // RUNNER_WINDOWS_CONTENT_UPDATES_H_
