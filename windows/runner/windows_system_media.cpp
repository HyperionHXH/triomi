#include "windows_system_media.h"

#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <string>
#include <utility>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;

HWND window = nullptr;
UINT button_message = 0;
HRESULT runtime_result = E_UNEXPECTED;
bool runtime_initialized = false;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
SystemMediaTransportControls controls{nullptr};
winrt::event_token button_token{};
bool button_subscribed = false;
bool enabled = false;
bool can_next = false;
bool can_previous = false;
std::string active_owner;
// Never reset on teardown: a posted message for a destroyed/reused HWND must
// not become valid again when a new engine initializes this module.
WPARAM generation = 0;

const EncodableValue* Argument(const EncodableMap* args, const char* name) {
  if (!args) return nullptr;
  const auto it = args->find(EncodableValue(name));
  return it == args->end() ? nullptr : &it->second;
}

template <typename T>
const T* ReadArgument(const EncodableMap* args, const char* name) {
  const auto* value = Argument(args, name);
  return value ? std::get_if<T>(value) : nullptr;
}

void RevokeButtons() {
  ++generation;
  enabled = false;
  if (controls && button_subscribed) {
    controls.ButtonPressed(button_token);
    button_subscribed = false;
  }
}

void DisableControls() {
  if (!controls) return;
  controls.IsEnabled(false);
  controls.IsPlayEnabled(false);
  controls.IsPauseEnabled(false);
  controls.IsStopEnabled(false);
  controls.IsNextEnabled(false);
  controls.IsPreviousEnabled(false);
  controls.PlaybackStatus(MediaPlaybackStatus::Closed);
  const auto display = controls.DisplayUpdater();
  display.ClearAll();
  display.Update();
}

void ClearControls() {
  RevokeButtons();
  active_owner.clear();
  can_next = false;
  can_previous = false;
  DisableControls();
}

void EnsureControls() {
  winrt::check_hresult(runtime_result);
  if (!window || !IsWindow(window) || !button_message) {
    throw winrt::hresult_error(E_HANDLE, L"Main media window is unavailable");
  }
  if (controls) return;
  const auto interop = winrt::get_activation_factory<
      SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
  winrt::check_hresult(interop->GetForWindow(
      window, winrt::guid_of<SystemMediaTransportControls>(),
      winrt::put_abi(controls)));
}

void SubscribeButtons() {
  const HWND target = window;
  const UINT message = button_message;
  const WPARAM revision = generation;
  // ButtonPressed may arrive on a WinRT worker thread. Capture only immutable
  // scalars, and never touch Flutter, UI-owned state, or a dangling `this` here.
  button_token = controls.ButtonPressed(
      [target, message, revision](
          const SystemMediaTransportControls&,
          const winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs& args) {
        PostMessageW(target, message, revision,
                     static_cast<LPARAM>(args.Button()));
      });
  button_subscribed = true;
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  if (method != "update" && method != "clear") {
    result->NotImplemented();
    return;
  }
  const auto* args = call.arguments() ?
      std::get_if<EncodableMap>(call.arguments()) : nullptr;
  const auto* owner = ReadArgument<std::string>(args, "owner");
  if (!owner || owner->empty()) {
    result->Error("invalid_media_owner", "A media session owner is required");
    return;
  }
  try {
    if (method == "clear") {
      // A disposed Flutter page is allowed to finish clearing after a successor
      // has published. It can never clear that successor's native session.
      if (*owner == active_owner) ClearControls();
      result->Success();
      return;
    }
    const auto* requested_enabled = ReadArgument<bool>(args, "enabled");
    const auto* state = ReadArgument<std::string>(args, "state");
    const auto* title = ReadArgument<std::string>(args, "title");
    const auto* artist = ReadArgument<std::string>(args, "artist");
    const auto* next = ReadArgument<bool>(args, "canNext");
    const auto* previous = ReadArgument<bool>(args, "canPrevious");
    if (!requested_enabled || !state || !title || !artist || !next || !previous ||
        (*state != "playing" && *state != "paused" && *state != "stopped")) {
      result->Error("invalid_media_state", "Incomplete Windows media state");
      return;
    }
    const bool changed = active_owner != *owner || enabled != *requested_enabled;
    if (changed) RevokeButtons();
    active_owner = *owner;
    can_next = *next;
    can_previous = *previous;
    if (!*requested_enabled) {
      DisableControls();
      result->Success();
      return;
    }
    EnsureControls();
    controls.IsPlayEnabled(true);
    controls.IsPauseEnabled(true);
    controls.IsStopEnabled(true);
    controls.IsNextEnabled(can_next);
    controls.IsPreviousEnabled(can_previous);
    controls.PlaybackStatus(*state == "playing" ? MediaPlaybackStatus::Playing :
        (*state == "paused" ? MediaPlaybackStatus::Paused : MediaPlaybackStatus::Stopped));
    const auto display = controls.DisplayUpdater();
    display.Type(MediaPlaybackType::Video);
    const auto video = display.VideoProperties();
    video.Title(winrt::to_hstring(*title));
    // The Flutter artist field is the series/work name for video playback.
    video.Subtitle(winrt::to_hstring(*artist));
    display.Update();
    if (!button_subscribed) SubscribeButtons();
    enabled = true;
    controls.IsEnabled(true);
    result->Success();
  } catch (const winrt::hresult_error& error) {
    // A failed SDK/OS operation is observable; never acknowledge a fake session.
    try {
      ClearControls();
    } catch (const winrt::hresult_error&) {
      OutputDebugStringW(L"Triomi: failed to clear Windows system media controls\n");
    }
    result->Error("windows_system_media_failed", winrt::to_string(error.message()),
                  EncodableValue(EncodableMap{
                      {EncodableValue("hresult"),
                       EncodableValue(static_cast<int64_t>(error.code().value))}}));
  }
}
}  // namespace

void InitializeWindowsSystemMedia(flutter::BinaryMessenger* messenger, HWND owner) {
  CloseWindowsSystemMedia();
  window = owner;
  button_message = RegisterWindowMessageW(L"Triomi.WindowsSystemMedia.Button");
  runtime_result = RoInitialize(RO_INIT_SINGLETHREADED);
  runtime_initialized = SUCCEEDED(runtime_result);
  channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "triomi/windows-media", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(HandleCall);
}

bool WindowsSystemMediaOnMessage(HWND owner, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  if (!button_message || message != button_message || owner != window) return false;
  if (!channel || !enabled || wparam != generation || active_owner.empty()) return true;
  const char* command = nullptr;
  switch (static_cast<SystemMediaTransportControlsButton>(lparam)) {
    case SystemMediaTransportControlsButton::Play:
      command = "play";
      break;
    case SystemMediaTransportControlsButton::Pause:
      command = "pause";
      break;
    case SystemMediaTransportControlsButton::Stop:
      command = "stop";
      break;
    case SystemMediaTransportControlsButton::Next:
      if (can_next) command = "next";
      break;
    case SystemMediaTransportControlsButton::Previous:
      if (can_previous) command = "previous";
      break;
    default:
      break;
  }
  if (command) {
    channel->InvokeMethod("command", std::make_unique<EncodableValue>(EncodableMap{
        {EncodableValue("owner"), EncodableValue(active_owner)},
        {EncodableValue("command"), EncodableValue(command)}}));
  }
  return true;
}

void CloseWindowsSystemMedia() {
  if (channel) channel->SetMethodCallHandler(nullptr);
  channel.reset();
  try {
    ClearControls();
  } catch (const winrt::hresult_error&) {
    OutputDebugStringW(L"Triomi: Windows system media shutdown failed\n");
  }
  button_subscribed = false;
  controls = nullptr;
  window = nullptr;
  button_message = 0;
  if (runtime_initialized) RoUninitialize();
  runtime_initialized = false;
  runtime_result = E_UNEXPECTED;
}
