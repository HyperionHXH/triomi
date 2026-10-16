#ifndef TRIOMI_APP_UPDATE_H_
#define TRIOMI_APP_UPDATE_H_
#include <flutter/encodable_value.h>
#include <string>
// Reads the actual running PE version resource. Does not execute any candidate.
flutter::EncodableMap CurrentAppUpdateInfo();
flutter::EncodableMap AppUpdateExecutableInfo(const std::string& path);
#endif
