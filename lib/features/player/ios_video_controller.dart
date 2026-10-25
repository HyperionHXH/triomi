import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// State emitted by a native video platform view.
class NativeVideoState {
  const NativeVideoState({
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.playing,
  });

  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final bool playing;
}

/// Common Dart seam for native video implementations.
///
/// Android keeps its existing channel contract; iOS uses AVPlayer through
/// `triomi/ios-video/<viewId>`.
abstract class VideoPlatformController {
  Widget buildView();
  Future<void> setUrl(
    String url, {
    Map<String, String> headers,
    String? mimeType,
    bool omitCookies,
    Duration startPosition,
    String title,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> setAspectRatio(double? ratio);
  Future<void> setBackgroundAudio(bool enabled);
  Future<List<Map<Object?, Object?>>> subtitleTracks();
  Future<void> selectSubtitle(String? id);
  void dispose();
}

/// iOS AVPlayer platform-view controller.
class IosVideoController implements VideoPlatformController {
  IosVideoController({
    required this.onState,
    required this.onPrepared,
    required this.onError,
    required this.onCompleted,
    required this.onPip,
  });

  final void Function(NativeVideoState state) onState;
  final void Function(NativeVideoState state) onPrepared;
  final void Function(String message) onError;
  final VoidCallback onCompleted;
  final void Function(bool enabled) onPip;

  MethodChannel? _channel;
  int? _viewId;
  String? _pendingUrl;
  String? _pendingMimeType;
  bool _pendingOmitCookies = false;
  Map<String, String> _pendingHeaders = const <String, String>{};
  Duration _pendingStartPosition = Duration.zero;
  String _pendingTitle = 'Triomi';
  bool _disposed = false;

  void attach(int id) {
    if (_disposed) return;
    _channel?.setMethodCallHandler(null);
    _viewId = id;
    final channel = MethodChannel('triomi/ios-video/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map
          ? Map<Object?, Object?>.from(call.arguments as Map)
          : const <Object?, Object?>{};
      switch (call.method) {
        case 'state':
          final state = _stateFrom(args);
          _pendingStartPosition = state.position;
          onState(state);
        case 'prepared':
          final preparedState = _stateFrom(args);
          _pendingStartPosition = preparedState.position;
          onPrepared(preparedState);
        case 'completed':
          onState(_stateFrom(args));
          onCompleted();
        case 'pip':
          onPip(args['enabled'] == true);
        case 'error':
          final message = args['message']?.toString().trim();
          onError(message == null || message.isEmpty ? '原生播放器发生错误' : message);
      }
    });
    final url = _pendingUrl;
    if (url != null) {
      unawaited(
        setUrl(
          url,
          headers: _pendingHeaders,
          mimeType: _pendingMimeType,
          omitCookies: _pendingOmitCookies,
          startPosition: _pendingStartPosition,
          title: _pendingTitle,
        ).catchError((Object error) => onError('打开视频失败：$error')),
      );
    }
  }

  NativeVideoState _stateFrom(Map<Object?, Object?> args) {
    int number(String key) => (args[key] as num?)?.toInt() ?? 0;
    return NativeVideoState(
      position: Duration(milliseconds: number('positionMs')),
      duration: Duration(milliseconds: number('durationMs')),
      bufferedPosition: Duration(milliseconds: number('bufferedPositionMs')),
      playing: args['playing'] == true,
    );
  }

  @override
  Future<void> setUrl(
    String url, {
    Map<String, String> headers = const <String, String>{},
    String? mimeType,
    bool omitCookies = false,
    Duration startPosition = Duration.zero,
    String title = 'Triomi',
  }) async {
    if (_disposed) return;
    _pendingUrl = url;
    _pendingHeaders = headers;
    _pendingMimeType = mimeType;
    _pendingOmitCookies = omitCookies;
    _pendingStartPosition = startPosition;
    _pendingTitle = title;
    final channel = _channel;
    if (channel == null) return;
    await channel.invokeMethod<void>('open', <String, Object?>{
      'url': url,
      'headers': headers,
      'mimeType': ?mimeType,
      'omitCookies': omitCookies,
      'startMs': startPosition.inMilliseconds,
      'title': title,
    });
  }

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seek(Duration position) =>
      _invoke('seek', <String, Object?>{'positionMs': position.inMilliseconds});

  @override
  Future<void> setRate(double rate) =>
      _invoke('setRate', <String, Object?>{'rate': rate});

  @override
  Future<void> setVolume(double volume) =>
      _invoke('setVolume', <String, Object?>{'volume': volume});

  @override
  Future<void> setAspectRatio(double? ratio) =>
      _invoke('setAspectRatio', <String, Object?>{'ratio': ratio});

  @override
  Future<void> setBackgroundAudio(bool enabled) =>
      _invoke('setBackgroundAudio', <String, Object?>{'enabled': enabled});

  @override
  Future<List<Map<Object?, Object?>>> subtitleTracks() async {
    final raw = await _channel?.invokeListMethod<Object?>('subtitleTracks') ??
        const <Object?>[];
    return <Map<Object?, Object?>>[
      for (final row in raw)
        if (row is Map) Map<Object?, Object?>.from(row),
    ];
  }

  @override
  Future<void> selectSubtitle(String? id) =>
      _invoke('selectSubtitle', <String, Object?>{'id': id});

  Future<bool> enterPip() async {
    final result = await _channel?.invokeMethod<bool>('enterPip');
    return result == true;
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    final channel = _channel;
    if (_disposed || channel == null) return;
    await channel.invokeMethod<void>(method, args);
  }

  @override
  Widget buildView() => IosVideoView(controller: this);

  void detach(int id) {
    if (_viewId != id) return;
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _viewId = null;
  }

  @override
  void dispose() {
    _disposed = true;
    final channel = _channel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('dispose'));
      channel.setMethodCallHandler(null);
    }
    _channel = null;
  }
}

class IosVideoView extends StatefulWidget {
  const IosVideoView({required this.controller, super.key});

  final IosVideoController controller;

  @override
  State<IosVideoView> createState() => _IosVideoViewState();
}

class _IosVideoViewState extends State<IosVideoView> {
  int? _viewId;

  @override
  void dispose() {
    final id = _viewId;
    if (id != null) widget.controller.detach(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UiKitView(
        viewType: 'triomi/ios-video',
        onPlatformViewCreated: (id) {
          _viewId = id;
          widget.controller.attach(id);
        },
        layoutDirection: TextDirection.ltr,
        creationParams: const <String, Object?>{},
        creationParamsCodec: const StandardMessageCodec(),
      );
}

/// Exposed for tests and platform adapters that need to identify iOS.
bool get isIosVideoPlatform => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
