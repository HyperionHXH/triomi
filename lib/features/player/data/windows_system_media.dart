import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Owns the main Windows window's SMTC for one existing player page.
///
/// Replacement changes the wire owner before clearing native state, so an
/// already queued button from a previous episode cannot control its successor.
/// The native host never creates a player or resolves an episode URL.
/// Nested live player pages temporarily deactivate their predecessor; popping
/// the current page republishes the surviving page's latest state with a fresh
/// wire owner. Explicit disposal removes even an inactive page permanently.
class WindowsSystemMediaSession {
  WindowsSystemMediaSession({required this.onCommand}) {
    _current?._deactivate();
    _owners.add(this);
    _activate();
  }

  static const _channel = MethodChannel('triomi/windows-media');
  static WindowsSystemMediaSession? _current;
  static final _owners = <WindowsSystemMediaSession>[];
  static int _nextId = 0;

  final Future<void> Function(String command) onCommand;
  final int _id = ++_nextId;
  int _revision = 0;
  bool _disposed = false;
  bool _enabled = false;
  bool _canNext = false;
  bool _canPrevious = false;
  Map<String, Object>? _latestState;

  String get _owner => 'player:$_id:$_revision';
  bool get _isCurrent => !_disposed && identical(_current, this);

  void _deactivate() {
    if (!_isCurrent) return;
    final previous = _owner;
    ++_revision;
    _current = null;
    unawaited(_invoke('clear', {'owner': previous}));
  }

  void _activate() {
    _current = this;
    ++_revision;
    _channel.setMethodCallHandler(_handleCommand);
    final state = _latestState;
    if (state != null) {
      unawaited(_invoke('update', {'owner': _owner, ...state}));
    }
  }

  Future<void> _handleCommand(MethodCall call) async {
    final args = call.arguments;
    if (!_isCurrent || !_enabled || call.method != 'command' || args is! Map) {
      return;
    }
    if (args['owner'] != _owner) return;
    final command = args['command'];
    if (command is! String ||
        !const {
          'play',
          'pause',
          'stop',
          'next',
          'previous',
        }.contains(command) ||
        (command == 'next' && !_canNext) ||
        (command == 'previous' && !_canPrevious)) {
      return;
    }
    await onCommand(command);
  }

  /// Invalidates pending buttons immediately, before asynchronous source work.
  void replace() {
    if (_disposed) return;
    final previous = _owner;
    ++_revision;
    _enabled = false;
    _latestState = null;
    if (_isCurrent) unawaited(_invoke('clear', {'owner': previous}));
  }

  Future<void> update({
    required bool enabled,
    required String state,
    required String title,
    required String artist,
    required bool canNext,
    required bool canPrevious,
  }) async {
    if (_disposed) return;
    _enabled = enabled;
    _canNext = canNext;
    _canPrevious = canPrevious;
    final stateSnapshot = _latestState = <String, Object>{
      'enabled': enabled,
      'state': state,
      'title': title,
      'artist': artist,
      'canNext': canNext,
      'canPrevious': canPrevious,
    };
    if (_isCurrent) {
      await _invoke('update', {'owner': _owner, ...stateSnapshot});
    }
  }

  Future<void> _invoke(String method, Map<String, Object> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (error) {
      debugPrint('Windows system media $method failed: ${error.message}');
    } on MissingPluginException catch (error) {
      // Surface a missing host implementation instead of claiming success.
      debugPrint('Windows system media unavailable: $error');
    }
  }

  void dispose() {
    if (_disposed) return;
    final wasCurrent = _isCurrent;
    if (wasCurrent) _deactivate();
    _disposed = true;
    _enabled = false;
    _latestState = null;
    _owners.remove(this);
    if (!wasCurrent) return;
    if (_owners.isEmpty) {
      _channel.setMethodCallHandler(null);
    } else {
      _owners.last._activate();
    }
  }
}
