#include "windows_update_common.h"
#include "windows_update_revision.h"
#include <shellapi.h>

namespace {
using namespace triomi_update;

class WriterOwnership {
 public:
  ~WriterOwnership() { Release(); }
  void Acquire() {
    const auto sid = UserSid();
    LPWSTR raw = nullptr;
    Require(ConvertSidToStringSidW(const_cast<BYTE*>(sid.data()), &raw) != FALSE,
        "Cannot identify profile writer mutex");
    const std::wstring name = std::wstring(L"Global\\TriomiProfileWriter-") + raw;
    LocalFree(raw);
    mutex_.reset(CreateMutexW(nullptr, FALSE, name.c_str()));
    Require(static_cast<bool>(mutex_), "Cannot open profile writer mutex");
    // Same SID-scoped Global mutex as ProfileOwnership::Acquire. Do not wait
    // behind a second app writer: reject instead of updating its loaded files.
    const DWORD result = WaitForSingleObject(mutex_.get(), 0);
    Require(result == WAIT_OBJECT_0 || result == WAIT_ABANDONED,
        "Another Triomi profile writer is running; update cancelled without changing files");
    acquired_ = true;
  }
  void Release() {
    if (acquired_) { ReleaseMutex(mutex_.get()); acquired_ = false; }
    mutex_.reset();
  }
 private:
  Handle mutex_;
  bool acquired_ = false;
};

void Outcome(HANDLE file, const std::string& message) {
  Rewind(file);
  WriteAll(file, message.data(), static_cast<DWORD>(message.size()));
  Require(SetEndOfFile(file) && FlushFileBuffers(file), "Cannot preserve update outcome log");
}
void Notify(HANDLE pipe, const std::string& text) {
  WriteAll(pipe, text.data(), static_cast<DWORD>(text.size()));
}

void CheckDestinations(const Plan& p, Pins& pins) {
  const auto install = Parent(p.executable);
  pins.Directory(install);
  CheckWritable(p);
  for (const auto& f : p.files) {
    const auto full = install + L"\\" + f.path;
    size_t end = install.size();
    while ((end = full.find(L'\\', end + 1)) != std::wstring::npos) {
      const auto dir = full.substr(0, end);
      const DWORD attr = GetFileAttributesW(dir.c_str());
      if (attr == INVALID_FILE_ATTRIBUTES) {
        Require(GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND,
            "Cannot inspect install subdirectory");
        break;
      }
      pins.Directory(dir);
    }
    const DWORD attributes = GetFileAttributesW(full.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES) {
      Handle original(CreateFileW(full.c_str(), GENERIC_READ | DELETE | READ_CONTROL, FILE_SHARE_READ,
          nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
      Require(static_cast<bool>(original),
          "An installed file is locked or not writable without elevation; use the manual MSI");
      Normal(original.get(), false);
      Require(!(attributes & FILE_ATTRIBUTE_READONLY), "An installed file is read-only; use the manual MSI");
    } else {
      Require(GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND,
          "Cannot inspect installed file");
    }
  }
}

struct Entry {
  std::wstring destination;
  Handle original;
  Handle installed;
  bool backed_up = false;
};

// Original and replacement handles deny write/delete sharing throughout the
// transaction. Rollback renames the still-open original, never recopies bytes.
void Install(const Plan& p, const std::vector<Handle>& sources, Pins& pins, HANDLE log,
    bool& rollback_failed, std::wstring& recovery_directory) {
  const auto root = Parent(p.executable);
  const auto backup = Unique(root + L"\\.triomi-update-backup-");
  Require(CreateDirectoryW(backup.c_str(), nullptr) != FALSE, "Cannot create update rollback directory");
  recovery_directory = backup;
  auto backup_pins = std::make_unique<Pins>();
  backup_pins->Directory(backup, true);
  std::vector<Entry> entries;
  entries.reserve(p.files.size());
  bool committed = false;
  try {
    // Acquire every old file before making any change. A loaded/locked file
    // fails here, before an earlier member could have been overwritten.
    for (const auto& f : p.files) {
      Entry entry;
      entry.destination = root + L"\\" + f.path;
      const DWORD attr = GetFileAttributesW(entry.destination.c_str());
      if (attr != INVALID_FILE_ATTRIBUTES) {
        entry.original.reset(CreateFileW(entry.destination.c_str(), GENERIC_READ | DELETE | READ_CONTROL,
            FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        Require(static_cast<bool>(entry.original), "An installed file is locked or not writable; no update was applied");
        Normal(entry.original.get(), false);
      } else {
        Require(GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND,
            "Cannot inspect rollback target");
      }
      entries.emplace_back(std::move(entry));
    }
    for (size_t i = 0; i < entries.size(); ++i) {
      auto& entry = entries[i];
      size_t end = root.size();
      while ((end = entry.destination.find(L'\\', end + 1)) != std::wstring::npos) {
        const auto dir = entry.destination.substr(0, end);
        if (!CreateDirectoryW(dir.c_str(), nullptr))
          Require(GetLastError() == ERROR_ALREADY_EXISTS, "Cannot create installed application subdirectory");
        pins.Directory(dir);
      }
      if (entry.original) {
        RenameOpen(entry.original.get(), backup + L"\\" + std::to_wstring(i) + L".bak");
        entry.backed_up = true;
      }
      entry.installed = NewFile(entry.destination);
      Copy(sources[i].get(), entry.installed.get());
      Require(Size(entry.installed.get()) == p.files[i].size && Digest(entry.installed.get()) == p.files[i].hash,
          "Copied update failed content verification");
    }
    // Flush a commit record before discarding any recovery originals. A power
    // loss is not claimed to be atomic; backups remain inspectable on disk.
    Outcome(log, "installed\nAll manifest files copied and SHA256 verified. Restart pending.\n");
    committed = true;
  } catch (const std::exception& error) {
    const std::string reason = error.what();
    bool restored = true;
    for (auto it = entries.rbegin(); it != entries.rend(); ++it) {
      try {
        if (it->installed) { DeleteOpen(it->installed.get()); it->installed.reset(); }
        if (it->backed_up) { RenameOpen(it->original.get(), it->destination); it->backed_up = false; }
      } catch (...) { restored = false; }
    }
    // Directory pins are deliberately retained: empty directories are harmless
    // and no unrelated path is ever recursively removed.
    if (!restored) {
      rollback_failed = true;
      Outcome(log, "rollback_failed\nRecovery originals preserved in the installation's .triomi-update-backup-* directory.\n" + reason + "\n");
      Fail("Update rollback could not restore every file; recovery originals were preserved");
    }
    Outcome(log, "rolled_back\nOriginal application restored.\n" + reason + "\n");
    Fail(reason.c_str());
  }
  if (committed) {
    for (auto& entry : entries) {
      entry.installed.reset();
      if (entry.original) {
        // Cleanup failure is not an installation failure. Preserve the backup
        // rather than attempting rollback after some backups were discarded.
        FILE_DISPOSITION_INFO info{}; info.DeleteFile = TRUE;
        SetFileInformationByHandle(entry.original.get(), FileDispositionInfo, &info, sizeof(info));
        entry.original.reset();
      }
    }
  }
  backup_pins.reset();
  RemoveDirectoryW(backup.c_str());
}

void Restart(const Plan& p) {
  std::wstring command = Quote(p.executable);
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  Require(CreateProcessW(p.executable.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_UNICODE_ENVIRONMENT, nullptr, Parent(p.executable).c_str(), &startup, &process) != FALSE,
      "Application files are safe, but Windows could not restart triomi.exe; launch it manually");
  Handle child(process.hProcess), thread(process.hThread);
}
HANDLE Argument(const wchar_t* text) {
  Require(text && *text, "Missing inherited helper handle");
  uintptr_t value = 0;
  for (const wchar_t* p = text; *p; ++p) {
    Require(*p >= L'0' && *p <= L'9' && value <= (UINTPTR_MAX - 9) / 10,
        "Invalid inherited helper handle");
    value = value * 10 + static_cast<uintptr_t>(*p - L'0');
  }
  Require(value && value != UINTPTR_MAX, "Invalid inherited helper handle value");
  return reinterpret_cast<HANDLE>(value);
}
}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  using namespace triomi_update;
  Handle pipe;
  Handle log;
  Handle installing;
  Plan plan;
  std::wstring recovery_directory;
  bool ready = false, parent_exited = false, rollback_failed = false;
  bool installed = false, servicing_recorded = false, restarted = false;
  WriterOwnership writer;
  try {
    int argc = 0;
    LPWSTR* raw = CommandLineToArgvW(GetCommandLineW(), &argc);
    Require(raw != nullptr, "Cannot parse helper arguments");
    struct Args { LPWSTR* p; ~Args() { LocalFree(p); } } args{raw};
    Require(argc == 5 && std::wstring(raw[1]) == L"--apply", "Helper accepts only the private --apply protocol");
    Handle plan_file(Argument(raw[2]));
    Handle parent(Argument(raw[3]));
    pipe.reset(Argument(raw[4]));
    Require(GetFileType(pipe.get()) == FILE_TYPE_PIPE, "Invalid helper readiness channel");
    Normal(plan_file.get(), false); Owned(plan_file.get());
    plan = Decode(plan_file.get());
    Require(Same(Image(parent.get()), plan.executable), "Update destination is not the exact opened parent executable");
    Require(Same(Image(), plan.stage + L"\\" + kHelperName), "Helper must execute from its exclusive update stage");
    Require(WaitForSingleObject(parent.get(), 0) == WAIT_TIMEOUT, "Update parent already exited before handoff");
    Pins pins;
    pins.Directory(Parent(plan.payload), true);
    const auto marker = Parent(plan.payload) + L"\\installing";
    installing.reset(CreateFileW(marker.c_str(), GENERIC_WRITE | DELETE, FILE_SHARE_READ,
        nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
        FILE_FLAG_DELETE_ON_CLOSE, nullptr));
    Require(static_cast<bool>(installing), "This update bundle is already installing or cannot be protected");
    const char active[] = "Windows update helper owns this bundle until this marker disappears.\n";
    WriteAll(installing.get(), active, sizeof(active) - 1);
    Require(FlushFileBuffers(installing.get()) != FALSE, "Cannot protect active update bundle");
    auto sources = ValidatePayload(plan, pins);
    CheckDestinations(plan, pins);
    log = NewFile(plan.stage + L"\\outcome.txt");
    Outcome(log.get(), "ready\nValidated; waiting for exact application process exit. No application files changed.\n");
    Notify(pipe.get(), "READY\n");
    ready = true; pipe.reset();
    Require(WaitForSingleObject(parent.get(), kParentTimeout) == WAIT_OBJECT_0,
        "Application did not exit within 120 seconds; update cancelled without changing files");
    parent_exited = true;
    writer.Acquire();
    Install(plan, sources, pins, log.get(), rollback_failed, recovery_directory);
    installed = true;
    RecordInstalledRevision(plan.executable);
    servicing_recorded = true;
    writer.Release();
    Restart(plan);
    restarted = true;
    Outcome(log.get(), "success\nAll manifest files verified and installed; exact installed triomi.exe restarted.\n");
    return 0;
  } catch (const std::exception& error) {
    if (!ready && pipe) {
      try { Notify(pipe.get(), std::string("ERROR:") + error.what() + "\n"); } catch (...) {}
    }
    if (log) {
      try {
        // Append rather than overwrite the precise rollback result.
        LARGE_INTEGER zero{};
        SetFilePointerEx(log.get(), zero, nullptr, FILE_END);
        const std::string message = std::string("error: ") + error.what() + "\n";
        WriteAll(log.get(), message.data(), static_cast<DWORD>(message.size()));
        FlushFileBuffers(log.get());
      } catch (...) {}
    }
    writer.Release();
    if (ready && parent_exited && !rollback_failed && !restarted) {
      try { Restart(plan); restarted = true; } catch (...) {}
    }
    if (ready) {
      // Failures after READY cannot reach Dart. Always present a native outcome
      // rather than relying on the restarted app to discover a stage log.
      std::wstring message;
      if (rollback_failed) {
        message = L"The Windows update failed and automatic recovery could not restore every application file. "
            L"Triomi was not restarted. Do not launch this installation until its original files have been recovered.\n\n"
            L"Recovery backups:\n" + recovery_directory;
      } else if (installed) {
        if (!servicing_recorded) {
          message = L"The application files were updated, but Windows could not save installer downgrade protection. ";
          message += restarted ? L"Triomi was restarted."
              : L"Launch the installed triomi.exe manually if it is not already running.";
        } else {
          message = restarted
              ? L"The application files were updated and Triomi was restarted, but Windows could not finish recording the update outcome."
              : L"The application files were updated, but Windows could not restart Triomi. Launch the installed triomi.exe manually.";
        }
      } else {
        message = L"The Windows update was not installed. The original application files were kept or restored. ";
        message += restarted ? L"The original Triomi application was restarted."
            : L"If Triomi has closed, launch the original triomi.exe manually.";
      }
      message += L"\n\nUpdate outcome and error details:\n" + plan.stage + L"\\outcome.txt";
      message += L"\n\nYou can use the manual Windows installer if automatic updating is unavailable. "
          L"Preserve any recovery backups before reinstalling.";
      MessageBoxW(nullptr, message.c_str(), L"Triomi update failed",
          MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    }
    return 1;
  }
}
