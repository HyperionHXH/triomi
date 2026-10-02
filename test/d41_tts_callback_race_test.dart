import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/novel/reader/novel_blocks.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';

/// D41：TTS 控制器的回调竞态边界（在 D31 合同之上的补充回归）。
///
/// 覆盖：带令牌的完成回调（token 配对）、seek/stop 后迟到回调的丢弃、
/// speak 抛错的收口。与 `d31_tts_contract_test.dart`（状态机/规划/降级）
/// 互补，不重复。
void main() {
  List<ReaderBlock> sampleBlocks() => const <ReaderBlock>[
    ParagraphBlock('第一段'),
    ParagraphBlock('第二段'),
    ParagraphBlock('第三段'),
  ];

  group('带令牌的完成回调', () {
    test('令牌与活动 speak 配对：正常推进到下一段', () async {
      final engine = TokenEngine();
      final controller = TtsController(engine: engine, blocks: sampleBlocks());
      await controller.start(locked: false);

      // start 时的 speak 令牌是 1；引擎用令牌 1 报完成 → 推进。
      engine.completeWithToken(1);
      await Future<void>.delayed(Duration.zero);

      expect(controller.utteranceIndex, 1);
      expect(controller.state, TtsState.playing);
      expect(engine.spoken.last.text, '第二段');
    });

    test('seek 后旧令牌的迟到完成被丢弃，新段落照常朗读', () async {
      final engine = TokenEngine();
      final controller = TtsController(engine: engine, blocks: sampleBlocks());
      await controller.start(locked: false);

      // start 的 speak 令牌是 1；seek 到第 3 段后活动令牌变为 2。
      await controller.seekToUtterance(2);
      expect(engine.spoken.last.text, '第三段');
      expect(engine.stopCalled, 1, reason: 'seek 前先 stop 当前段');

      // 旧令牌 1 的迟到完成：令牌不匹配 → 丢弃。
      engine.completeWithStaleToken(1);
      await Future<void>.delayed(Duration.zero);
      expect(controller.utteranceIndex, 2, reason: '不推进');
      expect(controller.state, TtsState.playing);

      // 当前令牌 2 的完成：正常收尾。
      engine.completeWithToken(2);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, TtsState.completed, reason: '第三段是最后一段');
    });

    test('stop 后的迟到完成（带/不带令牌）都被丢弃，状态保持 idle', () async {
      final engine = TokenEngine();
      final controller = TtsController(engine: engine, blocks: sampleBlocks());
      await controller.start(locked: false);

      await controller.stop();
      expect(controller.state, TtsState.idle);

      engine.completeWithToken(1);
      engine.completeCurrent();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, TtsState.idle, reason: 'stop 后不再推进');
      expect(controller.progress, isNull);
      expect(engine.spoken, hasLength(1), reason: '没有新的 speak 被触发');
    });

    test('无令牌回调的文本校对：旧文本的迟到回调被丢弃', () async {
      final engine = TokenEngine();
      final controller = TtsController(engine: engine, blocks: sampleBlocks());
      await controller.start(locked: false);

      // seek 到第三段后，旧插件形态的引擎用**第一段的文本**报完成：
      // 文本与当前 utterance 不匹配 → 丢弃。
      await controller.seekToUtterance(2);
      engine.completeText('第一段');
      await Future<void>.delayed(Duration.zero);
      expect(controller.utteranceIndex, 2, reason: '文本不匹配的回调不推进');

      engine.completeText('第三段');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, TtsState.completed, reason: '匹配文本正常收尾');
    });
  });

  group('speak 抛错收口', () {
    test('speak 抛错：进入 error 态，不推进、不再 speak', () async {
      final engine = TokenEngine(speakError: StateError('TTS 引擎初始化失败'));
      final controller = TtsController(engine: engine, blocks: sampleBlocks());

      await controller.start(locked: false);

      expect(controller.state, TtsState.error);
      expect(engine.spoken, isEmpty, reason: '引擎抛错 = 没有受理任何朗读');

      // 错误态下迟到完成不推进。
      engine.completeWithToken(1);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, TtsState.error);
    });

    test('中途 speak 抛错：停在 error，已读段落不回滚', () async {
      final engine = TokenEngine();
      final controller = TtsController(engine: engine, blocks: sampleBlocks());
      await controller.start(locked: false);

      // 第一段正常完成后，让引擎在第二次 speak 时抛错。
      engine.speakError = StateError('合成失败');
      engine.completeCurrent();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, TtsState.error);
      expect(controller.utteranceIndex, 1, reason: '推进已发生，锚保持在第二段');
      expect(controller.progress?.anchor, 1);
    });
  });
}

/// 可控引擎替身：记录令牌并允许在任意时机注入完成/错误回调。
class TokenEngine implements TtsEngine {
  TokenEngine({this.supportsPause = true, this.speakError});

  @override
  final bool supportsPause;

  /// 非空时 speak 直接抛出（模拟引擎层故障）。
  Object? speakError;

  TtsEngineCallbacks? _callbacks;

  @override
  set callbacks(TtsEngineCallbacks value) => _callbacks = value;

  final List<TtsUtterance> spoken = <TtsUtterance>[];
  int stopCalled = 0;

  /// 最近一次 speak 的文本（即使被引擎拒绝）——错误态下的迟到回调要用。
  String? lastAttemptedText;

  @override
  Future<void> speak(TtsUtterance utterance) async {
    lastAttemptedText = utterance.text;
    if (speakError != null) throw speakError!;
    spoken.add(utterance);
  }

  @override
  Future<bool> pause() async => supportsPause;

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    stopCalled += 1;
  }

  // D48 语音选项：替身不关心语速/音色，显式落地保持 implements 完整。
  @override
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {}

  @override
  Future<List<TtsVoiceInfo>> availableVoices() async => const <TtsVoiceInfo>[];

  /// 用**当前活动令牌**发出完成回调（模拟支持令牌的插件）。
  void completeWithToken(int token) {
    _callbacks?.onCompleteWithToken?.call(
      spoken.isEmpty ? (lastAttemptedText ?? '') : spoken.last.text,
      token,
    );
  }

  /// 用**指定令牌**发出完成回调（模拟 seek/stop 之前的旧 speak 迟到）。
  void completeWithStaleToken(int staleToken) {
    _callbacks?.onCompleteWithToken?.call(spoken.last.text, staleToken);
  }

  /// 无令牌回调（旧插件形态，只有文本）。
  void completeCurrent() {
    _callbacks?.onComplete?.call(spoken.last.text);
  }

  /// 无令牌回调，但文本可指定（构造「旧文本的迟到回调」）。
  void completeText(String text) {
    _callbacks?.onComplete?.call(text);
  }
}
