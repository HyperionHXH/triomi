#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

#include "windows_backup.h"
int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const bool backup_worker = command_line_arguments.size() == 1 &&
      command_line_arguments.front() == "--triomi-local-backup";
  const bool worker = !command_line_arguments.empty() &&
      command_line_arguments.front() == "--triomi-js-worker";

  // Silent background jobs must never create a console or display a window.
  if (!backup_worker &&
      !::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Enforce a single profile writer before Flutter/plugins can open Hive or
  // SQLite. The OS releases this mutex even after crashes; never delete locks.
  ProfileOwnership profile;
  if (!worker && !profile.Acquire()) {
    if (!backup_worker) {
      ::MessageBoxW(nullptr,
          L"Triomi is already open, or a local backup is running. Please retry after it closes.",
          L"Triomi", MB_OK | MB_ICONINFORMATION);
    }
    // Task Scheduler records 32 as a safe skip (profile currently in use).
    return 32;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");


  HANDLE worker_job = nullptr;
  if (worker) {
    // Bound this worker's committed memory independently of Dart/QuickJS.
    // Fail closed when the OS cannot apply the limit.
    worker_job = ::CreateJobObject(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    limits.ProcessMemoryLimit = 384ULL * 1024 * 1024;
    if (!worker_job ||
        !::SetInformationJobObject(worker_job, JobObjectExtendedLimitInformation,
                                  &limits, sizeof(limits)) ||
        !::AssignProcessToJobObject(worker_job, ::GetCurrentProcess())) {
      if (worker_job) ::CloseHandle(worker_job);
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    project.set_dart_entrypoint("jsWorker");
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, worker, backup_worker);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"triomi", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg{};
  BOOL message_result;
  while ((message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // A hidden worker quits through WM_QUIT without receiving WM_CLOSE. Tear down
  // its engine while the derived window and channel are still alive, before
  // member destruction or COM uninitialization can dispatch stale callbacks.
  window.Destroy();
  ::CoUninitialize();
  return message_result < 0 ? EXIT_FAILURE : static_cast<int>(msg.wParam);
}
