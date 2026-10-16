#ifndef RUNNER_WINDOWS_BACKUP_H_
#define RUNNER_WINDOWS_BACKUP_H_

#include <windows.h>

#include <string>

// Both UI and backup runners must own this before starting Flutter or opening
// Hive/SQLite. JS sandbox processes never access the profile and are exempt.
class ProfileOwnership {
 public:
  ProfileOwnership() = default;
  ~ProfileOwnership();
  ProfileOwnership(const ProfileOwnership&) = delete;
  ProfileOwnership& operator=(const ProfileOwnership&) = delete;
  bool Acquire();

 private:
  HANDLE mutex_ = nullptr;
};

// Uses the current user's interactive token; no shell, password, elevation or
// command-line quoting of the executable is involved.
HRESULT SetLocalBackupSchedule(bool enabled);

#endif  // RUNNER_WINDOWS_BACKUP_H_
