/// Pure lifecycle model for the Android native video bridge.
///
/// The actual MediaPlayer and Surface stay in Kotlin
/// (`NativeVideoPlatformView.kt`). This model makes the contract testable
/// without an Android device: URL changes reset playback, prepared starts
/// when requested, completion stops playback, and a Surface rebuild
/// preserves position and the previous playing intent.
///
/// Contract notes from the G3/D13 review against the Kotlin implementation:
/// - `play`/`pause` before prepared only record the intent (Kotlin flips
///   `shouldPlay` and skips `start()`/`pause()` until the player exists);
///   the phase therefore stays `loading` until `onPrepared` arrives.
/// - `seek` before prepared is a no-op (Kotlin guards with `if (prepared)`).
/// - A zero duration (live stream / unknown container) must never crash
///   seek: with no known duration the clamp is a sentinel upper bound.
enum NativeVideoPhase {
  idle,
  loading,
  prepared,
  playing,
  paused,
  completed,
  error,
  surfaceDetached,
}

class NativeVideoState {
  const NativeVideoState({
    this.phase = NativeVideoPhase.idle,
    this.url,
    this.positionMs = 0,
    this.durationMs = 0,
    this.shouldPlay = true,
    this.error,
  });

  final NativeVideoPhase phase;
  final String? url;
  final int positionMs;
  final int durationMs;
  final bool shouldPlay;
  final String? error;

  bool get playing => phase == NativeVideoPhase.playing;

  NativeVideoState copyWith({
    NativeVideoPhase? phase,
    String? url,
    int? positionMs,
    int? durationMs,
    bool? shouldPlay,
    String? error,
    bool clearError = false,
  }) {
    return NativeVideoState(
      phase: phase ?? this.phase,
      url: url ?? this.url,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      shouldPlay: shouldPlay ?? this.shouldPlay,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class NativeVideoStateMachine {
  NativeVideoStateMachine({NativeVideoState initial = const NativeVideoState()})
    : state = initial;

  NativeVideoState state;

  /// Kotlin 侧真正存在可操作的 MediaPlayer 的相位；其余相位下
  /// `play`/`pause` 只记录意图，`seek` 被直接忽略。
  static const Set<NativeVideoPhase> _playerPhases = {
    NativeVideoPhase.prepared,
    NativeVideoPhase.playing,
    NativeVideoPhase.paused,
    NativeVideoPhase.completed,
  };

  void setUrl(String url) {
    state = NativeVideoState(
      phase: NativeVideoPhase.loading,
      url: url,
      shouldPlay: true,
    );
  }

  void onPrepared(int durationMs) {
    final phase = state.shouldPlay
        ? NativeVideoPhase.playing
        : NativeVideoPhase.prepared;
    state = state.copyWith(
      phase: phase,
      durationMs: durationMs.clamp(0, 1 << 31),
      positionMs: state.positionMs.clamp(
        0,
        durationMs > 0 ? durationMs : 1 << 31,
      ),
      clearError: true,
    );
  }

  void play() {
    state = state.copyWith(
      phase: _playerPhases.contains(state.phase)
          ? NativeVideoPhase.playing
          : state.phase,
      shouldPlay: true,
    );
  }

  void pause() {
    state = state.copyWith(
      phase: _playerPhases.contains(state.phase)
          ? NativeVideoPhase.paused
          : state.phase,
      shouldPlay: false,
    );
  }

  void seek(int positionMs) {
    // 未 prepared 的 seek 被 Kotlin 忽略（player 为 null 或未就绪）。
    if (!_playerPhases.contains(state.phase)) return;
    final max = state.durationMs > 0 ? state.durationMs : 1 << 31;
    state = state.copyWith(
      positionMs: positionMs.clamp(0, max),
      phase: state.playing ? NativeVideoPhase.playing : state.phase,
    );
  }

  void onPosition(int positionMs) {
    seek(positionMs);
  }

  void onCompleted() {
    state = state.copyWith(
      phase: NativeVideoPhase.completed,
      shouldPlay: false,
      positionMs: state.durationMs,
    );
  }

  void onError(String message) {
    state = state.copyWith(
      phase: NativeVideoPhase.error,
      shouldPlay: false,
      error: message,
    );
  }

  void onSurfaceDestroyed() {
    state = state.copyWith(phase: NativeVideoPhase.surfaceDetached);
  }

  void onSurfaceAvailable() {
    if (state.url == null) return;
    state = state.copyWith(phase: NativeVideoPhase.loading);
  }
}
