#ifndef RUNNER_WINDOWS_UPDATE_INSTALL_H_
#define RUNNER_WINDOWS_UPDATE_INSTALL_H_

#include <windows.h>
#include <flutter/encodable_value.h>

// Throws std::runtime_error on rejection/startup failure. Returns only after the
// isolated helper has validated its plan and is waiting for this exact process.
// The caller must then close the app through SystemNavigator.pop.
void LaunchWindowsUpdate(HWND owner, const flutter::EncodableMap& args);

#endif  // RUNNER_WINDOWS_UPDATE_INSTALL_H_
