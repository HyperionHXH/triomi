#ifndef RUNNER_DESKTOP_MIHON_RUNTIME_H_
#define RUNNER_DESKTOP_MIHON_RUNTIME_H_

#include <windows.h>
#include <string>
#include <unordered_map>
#include <vector>

#if defined(TRIOMI_MIHON_ACCEPTANCE_RELEASE_FORBIDDEN)
#error Isolated acceptance mode must never be compiled into a Release artifact.
#endif

// Owns only processes launched by this instance, never a PID discovered on the
// machine. Closing the private job also kills all extension descendants.
class DesktopMihonRuntime {
 public:
  DesktopMihonRuntime() = default;
  ~DesktopMihonRuntime();
  DesktopMihonRuntime(const DesktopMihonRuntime&) = delete;
  DesktopMihonRuntime& operator=(const DesktopMihonRuntime&) = delete;

  bool Start(const std::string& root, const std::string& proxy_host,
             int proxy_port, DWORD* pid);
  void Stop();
  bool Alive() const;
  bool TrackVerifier(DWORD pid);
  bool UntrackVerifier(DWORD pid);
  bool ReplaceStateFile(const std::string& source,
                               const std::string& destination,
                               std::string* failure_stage, DWORD* error);
  static bool AcceptanceBuild();
  const std::string& StateFailureStage() const { return state_failure_stage_; }
  DWORD StateFailureError() const { return state_failure_error_; }

 private:
  HANDLE job_ = nullptr;
  HANDLE process_ = nullptr;
  DWORD pid_ = 0;
  HANDLE verifier_job_ = nullptr;
  std::unordered_map<DWORD, HANDLE> verifiers_;
  std::string state_failure_stage_;
  DWORD state_failure_error_ = ERROR_SUCCESS;
#if defined(TRIOMI_MIHON_ACCEPTANCE_BUILD)
  std::wstring acceptance_root_;
  std::vector<HANDLE> acceptance_directories_;
#endif
};

#endif  // RUNNER_DESKTOP_MIHON_RUNTIME_H_
