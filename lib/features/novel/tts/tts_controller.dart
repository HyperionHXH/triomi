import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../novel/reader/novel_blocks.dart';

/// TTS 朗读位置：正在朗读哪个排版块。
///
/// 与阅读器的 `_progressParagraph`（块下标）同一锚模型，不发明第二套位置。
typedef TtsAnchor = int;

/// 一条待朗读的语音单元（D31 合同：第一版按「段落」为 utterance 粒度）。
///
/// - 插图块产出 [isPlaceholder] = true 的占位 utterance（朗读替换词，如
///   「插图」），朗读会执行，但**不计入阅读进度锚**（见 [TtsProgress.anchor]）；
/// - 分页把一个段落切成多页时，跨页句子先按块拼接再交给引擎——本层只认
///   `List<ReaderBlock>`，分页是渲染层概念，不影响 utterance 划分。
class TtsUtterance {
  const TtsUtterance({
    required this.blockIndex,
    required this.text,
    this.isPlaceholder = false,
    this.pauseAfterMs = 0,
    this.token = 0,
  });

  /// 产出该 utterance 的排版块下标（`ReaderBlock` 序列中的位置）。
  final int blockIndex;

  /// 朗读文本（标题/段落原文；插图占位为替换词）。
  final String text;

  /// 是否为插图占位（占位不推进阅读锚）。
  final bool isPlaceholder;

  /// 朗读完该条后的建议停顿（标题/插图后停顿）。
  final int pauseAfterMs;
  final int token;
}

/// 朗读进度：朗读位置 + 阅读锚。
class TtsProgress {
  const TtsProgress({
    required this.utteranceIndex,
    required this.blockIndex,
    this.anchor,
  });

  /// 当前 utterance 在计划中的下标。
  final int utteranceIndex;

  /// 正在朗读的块下标（占位时为插图块下标）。
  final int blockIndex;

  /// 阅读器应显示的位置锚：最近一个非占位 utterance 的块下标；
  /// 还没读到任何可读块时为 null（占位不推进锚）。
  final TtsAnchor? anchor;
}

/// 引擎回调：utterance 完成 / 出错。
class TtsEngineCallbacks {
  TtsEngineCallbacks({this.onComplete, this.onCompleteWithToken, this.onError});

  /// 当前 utterance 自然播完（text 用于校对归属）。
  final void Function(String text)? onComplete;

  /// Preferred completion callback. [token] is issued for each speak call and
  /// lets the controller discard a late callback after seek/stop.
  final void Function(String text, int token)? onCompleteWithToken;

  /// 引擎层错误（合成失败、引擎不可用等）。
  final void Function(Object error)? onError;
}

/// 系统音色（D48）：名称 + 语言区域，仅来自引擎实际返回的可用项。
class TtsVoiceInfo {
  const TtsVoiceInfo({required this.name, required this.locale});

  final String name;
  final String locale;

  String get label => '$name（$locale）';

  @override
  bool operator ==(Object other) =>
      other is TtsVoiceInfo && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

/// TTS 引擎抽象（D31 合同）：插件实现由 Codex 提供（D37 flutter_tts 接线），
/// 本层与测试只依赖接口。
///
/// 契约：
/// - [speak] 返回即表示引擎已受理；完成由 [callbacks] 的 onComplete 通知；
/// - [pause] 平台差异大（Android 需要 workaround、Windows 无 speech marks），
///   返回 false 表示平台不支持——控制器按「停止当前段、恢复时重读」降级；
/// - [stop] 必须幂等。
abstract class TtsEngine {
  bool get supportsPause;

  /// 引擎把完成/错误回调报到这里（控制器构造时注入）。
  set callbacks(TtsEngineCallbacks value);

  Future<void> speak(TtsUtterance utterance);

  /// @return 平台是否真正支持暂停（false → 调用方按停止-重读降级）。
  Future<bool> pause();

  Future<void> resume();

  Future<void> stop();

  /// 语音选项（D48）：会话开始前应用一次。默认实现为「无选项」，供
  /// 测试替身与不支持音色/语速的平台直接复用；真实引擎按需覆盖。
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {}

  /// 系统可用音色列表（D48）。默认返回空 = 平台未提供或查询不可用，
  /// 调用方按「系统默认音色」降级，不伪造选项。
  Future<List<TtsVoiceInfo>> availableVoices() async =>
      const <TtsVoiceInfo>[];
}

/// TTS 会话状态。
enum TtsState { idle, playing, paused, completed, error }

/// 朗读计划：utterance 序列（纯函数产出，可独立测试）。
class TtsPlan {
  const TtsPlan({required this.utterances});

  final List<TtsUtterance> utterances;

  static const String illustrationPlaceholder = '插图';

  /// 把排版块规划成 utterance 序列：
  /// - 标题/段落 → 原文，标题后停顿 [headingPauseMs]；
  /// - 插图 → 占位词（占位不计入阅读锚）；
  /// - 空白文本段落跳过（防御性处理）。
  static TtsPlan of(
    List<ReaderBlock> blocks, {
    String illustrationText = illustrationPlaceholder,
    int headingPauseMs = 240,
    int illustrationPauseMs = 360,
    int maxCharacters = 1800,
  }) {
    final utterances = <TtsUtterance>[];
    final limit = maxCharacters.clamp(1, 10000);
    void addText(int blockIndex, String text, {int pauseAfterMs = 0}) {
      final chunks = _splitText(text, limit);
      for (var i = 0; i < chunks.length; i++) {
        utterances.add(
          TtsUtterance(
            blockIndex: blockIndex,
            text: chunks[i],
            pauseAfterMs: i == chunks.length - 1 ? pauseAfterMs : 0,
          ),
        );
      }
    }
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      switch (block) {
        case HeadingBlock(:final text):
          if (text.trim().isEmpty) continue;
          addText(index, text, pauseAfterMs: headingPauseMs);
        case ParagraphBlock(:final text):
          if (text.trim().isEmpty) continue;
          addText(index, text);
        case IllustrationBlock():
          utterances.add(
            TtsUtterance(
              blockIndex: index,
              text: illustrationText,
              isPlaceholder: true,
              pauseAfterMs: illustrationPauseMs,
            ),
          );
      }
    }
    return TtsPlan(utterances: utterances);
  }

  /// Keep every engine request below the platform input limit.  A split keeps
  /// the original block index, so progress remains anchored to the same
  /// rendered paragraph even when a paragraph spans several utterances.
  static List<String> _splitText(String text, int limit) {
    final value = text.trim();
    if (value.length <= limit) return <String>[value];
    final result = <String>[];
    var start = 0;
    while (start < value.length) {
      final remaining = value.length - start;
      if (remaining <= limit) {
        result.add(value.substring(start).trim());
        break;
      }
      var end = start + limit;
      final window = value.substring(start, end);
      final breakAt = window.lastIndexOf(RegExp(r'[\n\r\t ，。！？；：、,.!?;:)]'));
      if (breakAt > limit ~/ 2) end = start + breakAt + 1;
      final chunk = value.substring(start, end).trim();
      if (chunk.isNotEmpty) result.add(chunk);
      start = end;
      while (start < value.length && value[start].trim().isEmpty) start++;
    }
    return result;
  }
}

/// TTS 控制器（D31 合同 + 纯 Dart seam）。
///
/// 职责：
/// - 持有 [TtsPlan]，按序驱动 [TtsEngine]；
/// - 维护 [state] 与 [progress]（朗读位置 + 阅读锚）；
/// - 锁定章**拒绝朗读**（`start` 抛错、引擎零调用——「不解锁不缓存」红线
///   在朗读域的镜像）；
/// - 引擎完成回调驱动推进；错误进入 [TtsState.error]；
/// - 平台不支持暂停时按「停止当前段、恢复重读」降级（第一版基线）。
///
/// 不含插件、音频焦点、前台服务与阅读器接线（Codex 自留 D37 范围）。
class TtsController extends ChangeNotifier {
  TtsController({required this._engine, required List<ReaderBlock> blocks})
    : _plan = TtsPlan.of(blocks) {
    _engine.callbacks = TtsEngineCallbacks(
      onComplete: _onUtteranceComplete,
      onCompleteWithToken: _onUtteranceCompleteWithToken,
      onError: _onUtteranceError,
    );
  }

  final TtsEngine _engine;
  final TtsPlan _plan;

  TtsState _state = TtsState.idle;
  int _utteranceIndex = -1;

  /// 阅读锚：最近一个非占位 utterance 的块下标。
  TtsAnchor? _anchor;

  /// 是否处于「降级暂停」（引擎不支持 pause，恢复时需要重读当前段）。
  bool _degradedPause = false;
  int _speakToken = 0;
  int _activeSpeakToken = 0;

  TtsState get state => _state;
  TtsPlan get plan => _plan;
  int get utteranceIndex => _utteranceIndex;

  /// 当前朗读进度（idle/completed/error 且未开始时为 null）。
  TtsProgress? get progress {
    if (_utteranceIndex < 0 || _utteranceIndex >= _plan.utterances.length) {
      return null;
    }
    final utterance = _plan.utterances[_utteranceIndex];
    return TtsProgress(
      utteranceIndex: _utteranceIndex,
      blockIndex: utterance.blockIndex,
      anchor: _anchor,
    );
  }

  /// 引擎是否支持暂停（透传，供 UI 决定按钮形态）。
  bool get supportsPause => _engine.supportsPause;

  /// 开始朗读。锁定章直接拒绝（引擎零调用，状态置 error）。
  Future<void> start({required bool locked}) async {
    if (_state == TtsState.playing || _state == TtsState.paused) return;
    if (locked) {
      _state = TtsState.error;
      throw StateError('锁定章节不提供朗读');
    }
    if (_plan.utterances.isEmpty) {
      _state = TtsState.completed;
      return;
    }
    _state = TtsState.playing;
    _utteranceIndex = 0;
    _anchor = null;
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final token = ++_speakToken;
    _activeSpeakToken = token;
    final utterance = _plan.utterances[_utteranceIndex];
    if (!utterance.isPlaceholder) {
      _anchor = utterance.blockIndex;
    }
    notifyListeners();
    try {
      await _engine.speak(
        TtsUtterance(
          blockIndex: utterance.blockIndex,
          text: utterance.text,
          isPlaceholder: utterance.isPlaceholder,
          pauseAfterMs: utterance.pauseAfterMs,
          token: token,
        ),
      );
    } catch (error) {
      if (token == _activeSpeakToken && _state == TtsState.playing) {
        _onUtteranceError(error);
      }
    }
  }

  /// 暂停：引擎不支持时降级为「停止当前段，恢复时重读」。
  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _state = TtsState.paused;
    notifyListeners();
    final supported = await _engine.pause();
    _degradedPause = !supported;
    if (!supported) await _engine.stop();
  }

  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    _state = TtsState.playing;
    if (_degradedPause) {
      _degradedPause = false;
      await _speakCurrent(); // 不支持暂停的平台：重读当前段。
      return;
    }
    await _engine.resume();
  }

  /// 停止：回到 idle，进度清零。
  Future<void> stop() async {
    if (_state == TtsState.idle) return;
    _activeSpeakToken = -1;
    _state = TtsState.idle;
    _utteranceIndex = -1;
    _anchor = null;
    _degradedPause = false;
    notifyListeners();
    await _engine.stop();
  }

  /// 跳到指定 utterance（UI 点选段落/上一段/下一段用）。
  Future<void> seekToUtterance(int index) async {
    if (index < 0 || index >= _plan.utterances.length) return;
    _activeSpeakToken = -1;
    _state = TtsState.paused;
    await _engine.stop();
    _utteranceIndex = index;
    _state = TtsState.playing;
    await _speakCurrent();
  }

  void _onUtteranceComplete(String text) {
    _onUtteranceCompleteInternal(text, null);
  }

  void _onUtteranceCompleteWithToken(String text, int token) {
    _onUtteranceCompleteInternal(text, token);
  }

  void _onUtteranceCompleteInternal(String text, int? token) {
    if (_state != TtsState.playing) return;
    if (token != null && token != _activeSpeakToken) return;
    final current = _plan.utterances[_utteranceIndex];
    if (current.text != text) return; // 迟到的旧回调：丢弃。
    if (_utteranceIndex + 1 >= _plan.utterances.length) {
      _state = TtsState.completed;
      notifyListeners();
      return;
    }
    _utteranceIndex += 1;
    unawaited(_speakCurrent());
  }

  void _onUtteranceError(Object error) {
    _state = TtsState.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _state = TtsState.idle;
    _activeSpeakToken = -1;
    _engine.callbacks = TtsEngineCallbacks();
    unawaited(_engine.stop().catchError((Object _) {}));
    super.dispose();
  }
}
