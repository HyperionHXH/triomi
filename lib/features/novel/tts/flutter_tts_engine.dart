import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'tts_controller.dart';

final ttsEngineFactoryProvider = Provider<TtsEngine Function()>(
  (ref) => FlutterTtsEngine.new,
);

bool get ttsPlatformSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Each speak Future owns its token. Global completion callbacks have no ID
/// and cannot safely distinguish repeated paragraphs after a seek.
class FlutterTtsEngine implements TtsEngine {
  FlutterTtsEngine({FlutterTts? plugin, this.synthesisTimeout})
    : _plugin = plugin ?? FlutterTts();

  final FlutterTts _plugin;

  /// Optional bound for device tests; normal paragraphs scale with text/rate.
  final Duration? synthesisTimeout;
  TtsEngineCallbacks _callbacks = TtsEngineCallbacks();
  Future<void>? _initialization;
  int _generation = 0;

  // D48 语音选项：会话开始前由调用方注入，初始化/下一次 speak 前应用。
  // 默认语速 0.5，初始化时总是应用一次（未设置选项的会话也显式落到插件）。
  double _pendingRate = 0.5;
  TtsVoiceInfo? _pendingVoice;
  bool _settingsDirty = true;

  @override
  bool get supportsPause => false;

  @override
  set callbacks(TtsEngineCallbacks value) => _callbacks = value;

  Future<void> _initialize() async {
    await _plugin.awaitSpeakCompletion(true);
    await _plugin.setLanguage('zh-CN');
    await _applyPendingSettings();
  }

  /// 把待应用的语音选项写进插件（幂等，仅在选项变化后执行一次）。
  Future<void> _applyPendingSettings() async {
    if (!_settingsDirty) return;
    final rate = _pendingRate;
    await _plugin.setSpeechRate(rate);
    final voice = _pendingVoice;
    if (voice != null) {
      await _plugin.setVoice({'name': voice.name, 'locale': voice.locale});
    }
    _settingsDirty = false;
  }

  @override
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {
    if (rate != null) _pendingRate = rate;
    if (voice != null) _pendingVoice = voice;
    _settingsDirty = true;
  }

  @override
  Future<List<TtsVoiceInfo>> availableVoices() async {
    try {
      final raw = await _plugin.getVoices;
      if (raw is! List) return const <TtsVoiceInfo>[];
      return <TtsVoiceInfo>[
        for (final entry in raw)
          if (entry is Map &&
              entry['name'] is String &&
              entry['locale'] is String)
            TtsVoiceInfo(
              name: entry['name'] as String,
              locale: entry['locale'] as String,
              networkRequired: entry['network_required'] == '1',
              installed: !(entry['features']?.toString() ?? '').contains(
                'notInstalled',
              ),
            ),
      ];
    } on PlatformException {
      return const <TtsVoiceInfo>[];
    } on MissingPluginException {
      return const <TtsVoiceInfo>[];
    }
  }

  @override
  Future<void> speak(TtsUtterance utterance) async {
    final generation = ++_generation;
    await (_initialization ??= _initialize());
    if (generation != _generation) return;
    await _applyPendingSettings();
    if (generation != _generation) return;
    unawaited(_synthesize(utterance, generation));
  }

  Future<void> _synthesize(TtsUtterance utterance, int generation) async {
    try {
      // Android's plugin does not resolve awaitSpeakCompletion on synthesis
      // errors. Bound that Future without relying on global callbacks lacking
      // utterance IDs, which can belong to a previous paragraph after a seek.
      final seconds =
          (utterance.text.length / (5 * _pendingRate.clamp(0.1, 1)) + 20)
              .ceil()
              .clamp(30, 600);
      final result = await _plugin
          .speak(utterance.text, focus: true)
          .timeout(synthesisTimeout ?? Duration(seconds: seconds));
      if (generation != _generation) return;
      if (result != 1) throw StateError('语音引擎未完成朗读');
      if (utterance.pauseAfterMs > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: utterance.pauseAfterMs),
        );
      }
      if (generation != _generation) return;
      _callbacks.onCompleteWithToken?.call(utterance.text, utterance.token);
    } catch (error) {
      if (generation == _generation) {
        ++_generation;
        // Release plugin pending result/audio focus before a user retries.
        try {
          await _plugin.stop();
        } catch (_) {
          /* Preserve synthesis error. */
        }
        if (_generation == generation + 1) {
          _callbacks.onError?.call(
            error is TimeoutException
                ? StateError('语音引擎未完成朗读，请检查语音资源和网络后重试')
                : error,
          );
        }
      }
    }
  }

  @override
  Future<bool> pause() async => false;

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    ++_generation;
    await _plugin.stop();
  }
}
