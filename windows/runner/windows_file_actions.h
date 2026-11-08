#pragma once

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <string>

// Returns false without consuming result for methods owned by another host.
bool HandleWindowsFileAction(
    HWND owner, const std::string& method,
    const flutter::EncodableValue* args,
    flutter::MethodResult<flutter::EncodableValue>* result);
