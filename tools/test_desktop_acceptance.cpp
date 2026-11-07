// Standalone native boundary test; compile with TRIOMI_MIHON_ACCEPTANCE_BUILD.
// Including the implementation exercises the exact private path validators.
#include "../windows/runner/desktop_mihon_runtime.cpp"

#include <filesystem>
#include <iostream>

int main() {
  const std::string base =
      "D:/noval_and_manga/_tools/jm-apk-debug/windows-flutter-acceptance-native-" +
      std::to_string(GetCurrentProcessId());
  const std::string root_text = base + "/support/mihon-desktop";
  std::wstring root;
  if (!AcceptanceRoot(root_text, &root)) return 1;
  const std::string rejected[] = {
      "C:/Users/test/AppData/Roaming/io.github.hyperionhxh/triomi/mihon-desktop",
      base + "/../windows-flutter-acceptance-other/support/mihon-desktop",
      base + "/support/mihon-desktop:stream", base + "/support/mihon-desktop ",
      base + "/nested/support/mihon-desktop",
      "D:/noval_and_manga/_tools/jm-apk-debug/windows-flutter-acceptance-/support/mihon-desktop",
  };
  for (const auto& text : rejected) {
    std::wstring invalid;
    if (AcceptanceRoot(text, &invalid)) return 2;
  }
  if (std::filesystem::exists(base)) return 3;
  std::filesystem::create_directories(root);
  {
    AcceptanceDirectoryPins pins;
    if (!PinAcceptanceRoot(root, &pins.handles) || pins.handles.empty()) return 4;
    if (MoveFileW(root.c_str(), (root + L"-moved").c_str())) return 5;
    const DWORD rename_error = GetLastError();
    if (rename_error != ERROR_SHARING_VIOLATION &&
        rename_error != ERROR_ACCESS_DENIED) return 5;
    ScopedHandle other(CreateFileW(root.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (other.get() == INVALID_HANDLE_VALUE ||
        !SameFile(other.get(), pins.handles.back())) return 6;
  }
  DesktopMihonRuntime runtime;
  std::string stage;
  DWORD error = ERROR_SUCCESS;
  if (runtime.ReplaceStateFile(root_text + "/state.json.part",
      root_text + "/state.json", &stage, &error) ||
      stage != "validate_acceptance_runtime_root" ||
      error != ERROR_ACCESS_DENIED) return 7;
  std::filesystem::remove(root);
  std::filesystem::remove(std::filesystem::path(root).parent_path());
  std::filesystem::remove(base);
  std::cout << "acceptance path boundary, pinned ancestors, runtime binding: passed\n";
  return 0;
}
