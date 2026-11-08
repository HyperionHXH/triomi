#include "windows_playback_feedback.h"

#include <shobjidl.h>
#include <wrl/client.h>

#include <cmath>
#include <cstdint>
#include <set>
#include <string>
#include <utility>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

struct ProgressOwner {
  bool begun = false;
  bool active = false;
  bool has_progress = false;
  double progress = 0;
};

HWND window = nullptr;
UINT taskbar_created = 0;
Microsoft::WRL::ComPtr<ITaskbarList3> taskbar;
std::set<std::string> display_owners;
ProgressOwner downloads;
ProgressOwner app_update;
EXECUTION_STATE execution_state = ES_CONTINUOUS;

const EncodableValue* Argument(const EncodableMap* args, const char* name) {
  if (!args) return nullptr;
  const auto it = args->find(EncodableValue(name));
  return it == args->end() ? nullptr : &it->second;
}

bool ApplyExecutionState() {
  EXECUTION_STATE requested = ES_CONTINUOUS;
  if (!display_owners.empty()) requested |= ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED;
  if (downloads.active || app_update.active) requested |= ES_SYSTEM_REQUIRED;
  if (requested == execution_state) return true;
  if (!SetThreadExecutionState(requested)) return false;
  execution_state = requested;
  return true;
}

bool EnsureTaskbar() {
  if (taskbar) return true;
  Microsoft::WRL::ComPtr<ITaskbarList3> candidate;
  if (FAILED(CoCreateInstance(__uuidof(TaskbarList), nullptr, CLSCTX_INPROC_SERVER,
                             IID_PPV_ARGS(candidate.GetAddressOf()))) ||
      FAILED(candidate->HrInit())) {
    return false;
  }
  taskbar = std::move(candidate);
  return true;
}

bool RenderProgress() {
  if (!window || !EnsureTaskbar()) return false;
  // An installer download takes precedence, without destroying queue state.
  // Ending it restores a simultaneously active chapter download immediately.
  const ProgressOwner* selected = app_update.active ? &app_update :
      (downloads.active ? &downloads : nullptr);
  const TBPFLAG state = !selected ? TBPF_NOPROGRESS :
      (selected->has_progress ? TBPF_NORMAL : TBPF_INDETERMINATE);
  if (FAILED(taskbar->SetProgressState(window, state))) return false;
  if (selected && selected->has_progress) {
    constexpr ULONGLONG total = 10000;
    const auto completed = static_cast<ULONGLONG>(selected->progress * total);
    return SUCCEEDED(taskbar->SetProgressValue(window, completed, total));
  }
  return true;
}

bool ReadProgress(const EncodableMap* args, double* progress) {
  const auto* value = Argument(args, "progress");
  if (!value) return false;
  if (const auto* number = std::get_if<double>(value)) {
    *progress = *number;
  } else if (const auto* integer = std::get_if<int32_t>(value)) {
    *progress = static_cast<double>(*integer);
  } else if (const auto* wide_integer = std::get_if<int64_t>(value)) {
    *progress = static_cast<double>(*wide_integer);
  } else {
    return false;
  }
  return std::isfinite(*progress) && *progress >= 0 && *progress <= 1;
}

void ExecutionFailure(flutter::MethodResult<EncodableValue>* result) {
  result->Error("execution_state_failed", "Windows rejected the keep-awake request");
}
}  // namespace

void InitializeWindowsPlaybackFeedback(HWND owner) {
  CloseWindowsPlaybackFeedback();
  window = owner;
  taskbar_created = RegisterWindowMessageW(L"TaskbarButtonCreated");
}

bool HandleWindowsPlaybackFeedback(
    const flutter::MethodCall<EncodableValue>& call,
    flutter::MethodResult<EncodableValue>* result) {
  const auto& method = call.method_name();
  const bool keep_screen = method == "keepScreenOn";
  const bool begin_download = method == "beginDownloadQueue";
  const bool set_download = method == "setDownloadQueueActive";
  const bool update_download = method == "updateDownloadQueue";
  const bool end_download = method == "endDownloadQueue";
  const bool begin_update = method == "beginAppUpdate";
  const bool update_update = method == "updateAppUpdate";
  const bool end_update = method == "endAppUpdate";
  if (!keep_screen && !begin_download && !set_download && !update_download &&
      !end_download && !begin_update && !update_update && !end_update) {
    return false;
  }
  if (!window || !IsWindow(window)) {
    result->Error("window_unavailable", "Playback feedback requires the main window");
    return true;
  }
  const auto* args = call.arguments() ?
      std::get_if<EncodableMap>(call.arguments()) : nullptr;
  if (keep_screen) {
    const bool* enabled = call.arguments() ?
        std::get_if<bool>(call.arguments()) : nullptr;
    const std::string* named_owner = nullptr;
    if (args) {
      const auto* enabled_value = Argument(args, "enabled");
      const auto* owner_value = Argument(args, "owner");
      enabled = enabled_value ? std::get_if<bool>(enabled_value) : nullptr;
      named_owner = owner_value ? std::get_if<std::string>(owner_value) : nullptr;
      if (!named_owner || named_owner->empty()) {
        result->Error("invalid_arguments", "keepScreenOn requires a nonempty owner");
        return true;
      }
    }
    if (!enabled) {
      result->Error("invalid_arguments", "keepScreenOn requires a boolean enabled value");
      return true;
    }
    static const std::string legacy_owner = "reader";
    const std::string& owner = named_owner ? *named_owner : legacy_owner;
    auto existing = display_owners.find(owner);
    if (*enabled) {
      const bool inserted = existing == display_owners.end();
      if (inserted) display_owners.insert(owner);
      if (!ApplyExecutionState()) {
        if (inserted) display_owners.erase(owner);
        ExecutionFailure(result);
        return true;
      }
    } else if (existing != display_owners.end()) {
      // Keep the node available for allocation-free rollback if Windows fails.
      auto removed = display_owners.extract(existing);
      if (!ApplyExecutionState()) {
        display_owners.insert(std::move(removed));
        ExecutionFailure(result);
        return true;
      }
    }
    result->Success(EncodableValue(true));
    return true;
  }

  auto& state = (begin_update || update_update || end_update) ? app_update : downloads;
  if (update_download || update_update) {
    double progress = 0;
    if (!ReadProgress(args, &progress)) {
      result->Error("invalid_arguments", "Progress must be a finite number from zero to one");
      return true;
    }
    if (!state.begun) {
      result->Success(EncodableValue(false));
      return true;
    }
    state.progress = progress;
    state.has_progress = true;
    result->Success(EncodableValue(RenderProgress()));
    return true;
  }

  const ProgressOwner previous = state;
  if (begin_download || begin_update) {
    if (!state.begun) {
      state = {};
      state.begun = true;
      // Downloads explicitly switch active at each item; an updater has one job.
      state.active = begin_update;
    }
  } else if (set_download) {
    const auto* active_value = Argument(args, "active");
    const auto* active = active_value ? std::get_if<bool>(active_value) : nullptr;
    if (!active) {
      result->Error("invalid_arguments", "Download activity requires a boolean active value");
      return true;
    }
    if (!state.begun) {
      result->Success(EncodableValue(false));
      return true;
    }
    state.active = *active;
    if (!*active) state.has_progress = false;
  } else {
    state = {};
  }
  if (!ApplyExecutionState()) {
    state = previous;
    ExecutionFailure(result);
    return true;
  }
  // A missing shell/taskbar must never prevent in-process downloads. This bool
  // acknowledges ownership only; update methods report actual shell rendering.
  RenderProgress();
  if (end_download || end_update) {
    result->Success();
  } else {
    result->Success(EncodableValue(true));
  }
  return true;
}

void WindowsPlaybackFeedbackOnMessage(UINT message) {
  if (!taskbar_created || message != taskbar_created) return;
  taskbar.Reset();
  RenderProgress();
}

void CloseWindowsPlaybackFeedback() {
  if (taskbar && window && IsWindow(window)) {
    taskbar->SetProgressState(window, TBPF_NOPROGRESS);
  }
  taskbar.Reset();
  display_owners.clear();
  downloads = {};
  app_update = {};
  if (execution_state != ES_CONTINUOUS) SetThreadExecutionState(ES_CONTINUOUS);
  execution_state = ES_CONTINUOUS;
  window = nullptr;
  taskbar_created = 0;
}
