import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The real input boundary, independent of the native decoder underneath it.
/// Controls are above blank-video gestures but inside the keyboard focus scope.
class PlayerInteractionSurface extends StatefulWidget {
  const PlayerInteractionSurface({
    super.key,
    required this.enabled,
    required this.session,
    required this.position,
    required this.duration,
    required this.volume,
    required this.brightness,
    required this.brightnessEnabled,
    required this.holdSpeed,
    required this.onTap,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onVolumeChanged,
    required this.onVolumeEnd,
    required this.onBrightnessChanged,
    required this.onHoldChanged,
    required this.child,
    this.controls,
    this.seekHudTop = 25,
  });

  final bool enabled;
  final int session;
  final Duration position;
  final Duration duration;
  final double volume;
  final double brightness;
  final bool brightnessEnabled;
  final double holdSpeed;
  final VoidCallback onTap;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onScrubStart;
  final ValueChanged<Duration> onScrubUpdate;

  /// Null cancels a preview without seeking the decoder.
  final ValueChanged<Duration?> onScrubEnd;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onVolumeEnd;
  final ValueChanged<double> onBrightnessChanged;
  final ValueChanged<bool> onHoldChanged;
  final Widget child;
  final Widget? controls;

  /// Keeps seek feedback below visible player chrome.
  final double seekHudTop;

  @override
  State<PlayerInteractionSurface> createState() =>
      _PlayerInteractionSurfaceState();
}

class _PlayerInteractionSurfaceState extends State<PlayerInteractionSurface>
    with WidgetsBindingObserver {
  final _focus = FocusNode(debugLabel: 'Player input');
  Timer? _hudTimer;
  Timer? _repeatTimer;
  LogicalKeyboardKey? _heldKey;
  Duration? _keyboardPosition;
  int _repeatStep = 15;
  bool _repeatReady = true;
  bool _foreground = true;
  bool _routeCurrent = true;
  bool _holding = false;
  Duration? _dragOrigin;
  Duration? _seekTarget;
  Duration _seekDelta = Duration.zero;
  double _dragDistance = 0;
  bool? _adjustBrightness;
  double _adjustOrigin = 0;
  double _adjustDistance = 0;
  bool? _levelHudBrightness;
  double _levelHudValue = 0;
  int _interactionGeneration = 0;

  bool get _active => widget.enabled && _foreground && _routeCurrent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    _focus.addListener(_onFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!_routeCurrent) _reset();
  }

  @override
  void didUpdateWidget(PlayerInteractionSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.session != oldWidget.session) _reset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _reset();
    if (mounted) setState(() {});
  }

  void _onFocus() {
    if (!_focus.hasFocus) {
      _reset();
      if (mounted) setState(() {});
    }
  }

  // Route/focus notifications may arrive during an ancestor's build.
  void _notify(VoidCallback callback) {
    final generation = _interactionGeneration;
    final session = widget.session;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _interactionGeneration &&
            session == widget.session) {
          callback();
        }
      });
    } else {
      callback();
    }
  }

  void _reset() {
    _hudTimer?.cancel();
    _clearKey();
    if (_dragOrigin != null) {
      _dragOrigin = null;
      final onEnd = widget.onScrubEnd;
      _notify(() => onEnd(null));
    }
    if (_adjustBrightness == false) _notify(widget.onVolumeEnd);
    _adjustBrightness = null;
    if (_holding) {
      _holding = false;
      final onHold = widget.onHoldChanged;
      _notify(() => onHold(false));
    }
    _seekTarget = null;
    _levelHudBrightness = null;
  }

  void _clearKey() {
    _heldKey = null;
    _keyboardPosition = null;
    _repeatStep = 15;
    _repeatReady = true;
    _repeatTimer?.cancel();
  }

  bool _ownsFocus(FocusNode node) =>
      node == _focus || node.ancestors.contains(_focus);

  KeyEventResult _onKey(KeyEvent event) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final arrow =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!arrow) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      if (key == _heldKey) _clearKey();
      final focusContext = node.context;
      final editing =
          focusContext?.widget is EditableText ||
          focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
      return _active && _ownsFocus(node) && !editing
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final focusContext = node.context;
    final editing =
        focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (!_active ||
        !_ownsFocus(node) ||
        editing ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      _clearKey();
      return KeyEventResult.ignored;
    }
    if (_dragOrigin != null || _adjustBrightness != null || _holding) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) {
        final value =
            (widget.volume + (key == LogicalKeyboardKey.arrowUp ? .1 : -.1))
                .clamp(0.0, 1.0);
        widget.onVolumeChanged(value);
        widget.onVolumeEnd();
        _showLevel(false, value);
        _hideHudLater();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      _clearKey();
      _heldKey = key;
      _keyboardPosition = widget.position;
      _seekRelative(key == LogicalKeyboardKey.arrowLeft ? -15 : 15);
      _throttleRepeat();
    } else if (event is KeyRepeatEvent && _heldKey == key && _repeatReady) {
      // OS repeats are capped at 5 accepted events/s. Both directions ramp
      // 20, 25, 30 seconds, then stay at 30 until key-up/focus/route loss.
      _repeatStep = (_repeatStep + 5).clamp(15, 30);
      _seekRelative(
        key == LogicalKeyboardKey.arrowLeft ? -_repeatStep : _repeatStep,
      );
      _throttleRepeat();
    }
    return KeyEventResult.handled;
  }

  void _throttleRepeat() {
    _repeatReady = false;
    _repeatTimer?.cancel();
    _repeatTimer = Timer(
      const Duration(milliseconds: 200),
      () => _repeatReady = true,
    );
  }

  Duration _clamp(Duration target) => Duration(
    milliseconds: target.inMilliseconds.clamp(
      0,
      widget.duration.inMilliseconds,
    ),
  );

  void _seekRelative(int seconds) {
    if (!_active || widget.duration <= Duration.zero) return;
    final origin = _keyboardPosition ?? widget.position;
    final target = _clamp(origin + Duration(seconds: seconds));
    if (_heldKey != null) _keyboardPosition = target;
    setState(() {
      _seekTarget = target;
      _seekDelta = target - origin;
      _levelHudBrightness = null;
    });
    widget.onSeek(target);
    _hideHudLater();
  }

  void _hideHudLater() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) {
        setState(() {
          _seekTarget = null;
          _levelHudBrightness = null;
        });
      }
    });
  }

  void _showLevel(bool brightness, double value) {
    _hudTimer?.cancel();
    setState(() {
      _seekTarget = null;
      _levelHudBrightness = brightness;
      _levelHudValue = value;
    });
  }

  void _startScrub(DragStartDetails details) {
    if (!_active || widget.duration <= Duration.zero) return;
    ++_interactionGeneration;
    _clearKey();
    _hudTimer?.cancel();
    _dragOrigin = widget.position;
    _dragDistance = 0;
    widget.onScrubStart();
    setState(() {
      _seekTarget = _dragOrigin;
      _seekDelta = Duration.zero;
      _levelHudBrightness = null;
    });
  }

  void _updateScrub(DragUpdateDetails details, double width) {
    if (!_active || _dragOrigin == null || width <= 0) return;
    _dragDistance += details.delta.dx;
    final target = _clamp(
      _dragOrigin! +
          Duration(milliseconds: (_dragDistance / width * 180000).round()),
    );
    setState(() {
      _seekTarget = target;
      _seekDelta = target - _dragOrigin!;
    });
    widget.onScrubUpdate(target);
  }

  void _finishScrub({bool cancel = false}) {
    if (_dragOrigin == null) return;
    final target = _seekTarget;
    _dragOrigin = null;
    widget.onScrubEnd(cancel || !_active ? null : target);
    if (cancel || !_active) {
      setState(() => _seekTarget = null);
    } else {
      _hideHudLater();
    }
  }

  void _startAdjustment(DragStartDetails details, double width) {
    if (!_active) return;
    final brightness = details.localPosition.dx < width / 2;
    if (brightness && !widget.brightnessEnabled) return;
    ++_interactionGeneration;
    _clearKey();
    _adjustBrightness = brightness;
    _adjustOrigin = brightness ? widget.brightness : widget.volume;
    _adjustDistance = 0;
    _showLevel(brightness, _adjustOrigin);
  }

  void _updateAdjustment(DragUpdateDetails details, double height) {
    if (!_active || _adjustBrightness == null || height <= 0) return;
    _adjustDistance += details.delta.dy;
    final brightness = _adjustBrightness!;
    final value = (_adjustOrigin - _adjustDistance / height).clamp(
      brightness ? .05 : 0.0,
      1.0,
    );
    if (brightness) {
      widget.onBrightnessChanged(value);
    } else {
      widget.onVolumeChanged(value);
    }
    _showLevel(brightness, value);
  }

  void _finishAdjustment() {
    if (_adjustBrightness == null) return;
    if (_adjustBrightness == false) widget.onVolumeEnd();
    _adjustBrightness = null;
    _hideHudLater();
  }

  void _startHold() {
    if (!_active || _holding) return;
    ++_interactionGeneration;
    _clearKey();
    setState(() => _holding = true);
    widget.onHoldChanged(true);
  }

  void _endHold() {
    if (!_holding) return;
    setState(() => _holding = false);
    widget.onHoldChanged(false);
  }

  Widget _hud(IconData icon, String label, double progress, Key key) =>
      Positioned(
        top: key == const ValueKey('player-seek-hud') ? widget.seekHudTop : 25,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              key: key,
              width: 200,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .82),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: Colors.white12,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 2,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 3),
                        LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(2),
                          color: Colors.white,
                          backgroundColor: Colors.white30,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _levelHud() => Positioned(
    top: 25,
    left: 0,
    right: 0,
    child: IgnorePointer(
      child: Center(
        child: Container(
          key: const ValueKey('player-level-hud'),
          width: 200,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .82),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: Colors.white12,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _levelHudBrightness!
                      ? Icons.brightness_6_rounded
                      : (_levelHudValue == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded),
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_levelHudBrightness! ? '亮度' : '音量'} ${(_levelHudValue * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: _levelHudValue.clamp(0.0, 1.0),
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                      color: Colors.white,
                      backgroundColor: Colors.white30,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _speedHud() => Positioned(
    top: 25,
    left: 0,
    right: 0,
    child: IgnorePointer(
      child: Center(
        child: Container(
          key: const ValueKey('player-speed-hud'),
          width: 94,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.speed_rounded, color: Colors.white, size: 15),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${widget.holdSpeed}x',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  static String _time(Duration value) {
    final seconds = value.inSeconds;
    final minutes = seconds ~/ 60;
    return '${minutes ~/ 60 > 0 ? '${minutes ~/ 60}:' : ''}'
        '${minutes ~/ 60 > 0 ? (minutes % 60).toString().padLeft(2, '0') : '$minutes'}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_active)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => Listener(
                onPointerDown: (_) {
                  _focus.requestFocus();
                },
                onPointerUp: (_) => _endHold(),
                onPointerCancel: (_) {
                  // An accepted drag can emit onEnd for a cancelled pointer. Cancel
                  // before recognizers dispatch that terminal callback.
                  _finishScrub(cancel: true);
                  _finishAdjustment();
                  _endHold();
                },
                child: GestureDetector(
                  key: const ValueKey('player-blank-input'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onTap: widget.onTap,
                  onDoubleTap: () {
                    if (_active) widget.onTogglePlay();
                  },
                  onHorizontalDragStart: _startScrub,
                  onHorizontalDragUpdate: (details) =>
                      _updateScrub(details, constraints.maxWidth),
                  onHorizontalDragEnd: (_) => _finishScrub(),
                  onHorizontalDragCancel: () => _finishScrub(cancel: true),
                  onVerticalDragStart: (details) =>
                      _startAdjustment(details, constraints.maxWidth),
                  onVerticalDragUpdate: (details) =>
                      _updateAdjustment(details, constraints.maxHeight),
                  onVerticalDragEnd: (_) => _finishAdjustment(),
                  onVerticalDragCancel: _finishAdjustment,
                  onLongPressStart: (_) => _startHold(),
                  onLongPressEnd: (_) => _endHold(),
                  onLongPressCancel: _endHold,
                ),
              ),
            ),
          ),
        if (_active && _holding) _speedHud(),
        if (_active && _seekTarget != null)
          _hud(
            _seekDelta.isNegative
                ? Icons.fast_rewind_rounded
                : Icons.fast_forward_rounded,
            '${_time(_seekTarget!)} / ${_time(widget.duration)}\n'
            '${_seekDelta.isNegative ? '-' : '+'}${_seekDelta.inSeconds.abs()} 秒',
            widget.duration.inMilliseconds > 0
                ? _seekTarget!.inMilliseconds / widget.duration.inMilliseconds
                : 0,
            const ValueKey('player-seek-hud'),
          ),
        if (_active && _levelHudBrightness != null) _levelHud(),
        if (widget.controls != null) widget.controls!,
      ],
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    _hudTimer?.cancel();
    _repeatTimer?.cancel();
    // The page owns decoder teardown; no callback into a disposing ancestor.
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }
}
