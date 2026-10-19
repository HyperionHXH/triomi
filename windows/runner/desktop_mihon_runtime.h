#ifndef RUNNER_DESKTOP_MIHON_RUNTIME_H_
#define RUNNER_DESKTOP_MIHON_RUNTIME_H_

#include <windows.h>
#include <string>
#include <unordered_map>

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
  static bool ReplaceStateFile(const std::string& source,
                               const std::string& destination,
                               std::string* failure_stage, DWORD* error);

 private:
  HANDLE job_ = nullptr;
  HANDLE process_ = nullptr;
  DWORD pid_ = 0;
  HANDLE verifier_job_ = nullptr;
  std::unordered_map<DWORD, HANDLE> verifiers_;
};

#endif  // RUNNER_DESKTOP_MIHON_RUNTIME_H_
