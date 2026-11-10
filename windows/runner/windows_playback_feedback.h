#ifndef RUNNER_WINDOWS_PLAYBACK_FEEDBACK_H_
#define RUNNER_WINDOWS_PLAYBACK_FEEDBACK_H_

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>

// Foreground engine only. All functions, including shutdown, must run on the
// same COM-initialized platform/UI thread: execution-state requests are per thread.
void InitializeWindowsPlaybackFeedback(HWND owner);

// Forward triomi/platform calls before the shared handler's NotImplemented().
// Returns false without touching result for methods this module does not own.
// keepScreenOn: bool (legacy reader) or {enabled: bool, owner: string}.
// beginDownloadQueue / endDownloadQueue: no arguments.
// setDownloadQueueActive: {active: bool}.
// updateDownloadQueue: {progress: double in [0, 1], ...existing notification fields}.
// beginAppUpdate / endAppUpdate: no arguments; updateAppUpdate: {progress: double}.
// Begin/active success means an in-process execution lease, NOT a background
// service or a notification guarantee. Progress returns actual taskbar success.
bool HandleWindowsPlaybackFeedback(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    flutter::MethodResult<flutter::EncodableValue>* result);

// Call before Flutter's top-level window proc; does not consume the message.
// Recreates ITaskbarList3 and restores progress after Explorer restarts.
void WindowsPlaybackFeedbackOnMessage(UINT message);

// Before destroying HWND/engine and before CoUninitialize(). Clears taskbar
// progress, releases every execution-state owner and releases COM resources.
void CloseWindowsPlaybackFeedback();

#endif  // RUNNER_WINDOWS_PLAYBACK_FEEDBACK_H_
