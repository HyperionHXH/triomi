import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/novel/reader/novel_blocks.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';

/// D31：TTS 合同与纯 Dart seam（无插件）�?///
/// 覆盖：utterance 规划（段落粒�?标题停顿/插图占位）、状态机
/// （start→playing→completed）、暂�?恢复（含平台不支持降级）�?/// 停止、seek、锁定章拒绝（引擎零调用）、错误态�?void main() {
  List<ReaderBlock> sampleBlocks() => const <ReaderBlock>[
    HeadingBlock('第一�?启程'),
    ParagraphBlock('少年背起行囊，走出了山村�?),
    IllustrationBlock('https://example.com/ill-1.png'),
    ParagraphBlock('山路蜿蜒，他在暮色里看见了城墙�?),
  ];

  group('TtsPlan.of：utterance 规划', () {
    test('段落粒度：标�?段落原文，插图产出占�?utterance', () {
      final plan = TtsPlan.of(sampleBlocks());

      expect(plan.utterances, hasLength(4));
      expect(plan.utterances[0].text, '第一�?启程');
      expect(plan.utterances[0].blockIndex, 0);
      expect(plan.utterances[0].isPlaceholder, isFalse);
      expect(plan.utterances[0].pauseAfterMs, greaterThan(0),
          reason: '标题后建议停�?);

      expect(plan.utterances[1].text, '少年背起行囊，走出了山村�?);
      expect(plan.utterances[1].blockIndex, 1);
      expect(plan.utterances[1].pauseAfterMs, 0);

      expect(plan.utterances[2].text, TtsPlan.illustrationPlaceholder);
      expect(plan.utterances[2].blockIndex, 2);
      expect(plan.utterances[2].isPlaceholder, isTrue,
          reason: '插图占位必须打标记，进度锚靠它区�?);

      expect(plan.utterances[3].blockIndex, 3);
    });

    test('空文本段落跳过；全空块序列产出空计划', () {
      final plan = TtsPlan.of(const <ReaderBlock>[
        ParagraphBlock('   '),
        ParagraphBlock('正文'),
      ]);
      expect(plan.utterances, hasLength(1));
      expect(plan.utterances.single.blockIndex, 1,
          reason: '跳过空段后块下标保持原值，不重�?);

      expect(TtsPlan.of(const <ReaderBlock>[]).utterances, isEmpty);
    });

    test('占位词可自定义（繁简/无障碍场景）', () {
      final plan = TtsPlan.of(
        const <ReaderBlock>[IllustrationBlock('x')],
        illustrationText: '插圖',
      );
      expect(plan.utterances.single.text, '插圖');
    });

    test('long text splits safely while retaining the block anchor', () {
      final plan = TtsPlan.of(
        const <ReaderBlock>[ParagraphBlock('abcdefghij klmnopqrst uvwxyz')],
        maxCharacters: 10,
      );
      expect(plan.utterances, hasLength(3));
      expect(plan.utterances.every((item) => item.text.length <= 10), isTrue);
      expect(plan.utterances.map((item) => item.blockIndex), everyElement(0));
    });
  });

  group('TtsController：状态机', () {
    late FakeTtsEngine engine;
    late TtsController controller;

    setUp(() {
      engine = FakeTtsEngine();
      controller = TtsController(engine: engine, blocks: sampleBlocks());
    });

    test('start 后立即朗读第一条并进入 playing，锚=第一个可读块', () async {
      await controller.start(locked: false);

      expect(controller.state, TtsState.playing);
      expect(engine.spoken, hasLength(1));
      expect(engine.spoken.single.text, '第一�?启程');
      expect(controller.progress?.utteranceIndex, 0);
      expect(controller.progress?.anchor, 0);
    });

    test('逐条完成推进；插图占位被朗读但不推进阅读�?, () async {
      await controller.start(locked: false);
      await engine.completeCurrent(); // 标题完成 �?段落 1
      expect(controller.progress?.blockIndex, 1);
      expect(controller.progress?.anchor, 1);

      await engine.completeCurrent(); // 段落完成 �?插图占位
      expect(controller.progress?.blockIndex, 2);
      expect(controller.state, TtsState.playing);
      expect(controller.progress?.anchor, 1,
          reason: '占位朗读不推进阅读锚（保持上一个可读块�?);

      await engine.completeCurrent(); // 占位完成 �?段落 3
      expect(controller.progress?.blockIndex, 3);
      expect(controller.progress?.anchor, 3);
      expect(engine.spoken.last.isPlaceholder, isFalse);
    });

    test('最后一条完成后进入 completed，progress 仍指向最后一�?, () async {
      await controller.start(locked: false);
      while (controller.state != TtsState.completed) {
        final before = controller.utteranceIndex;
        await engine.completeCurrent();
        if (controller.utteranceIndex == before) break;
      }
      expect(controller.state, TtsState.completed);
      expect(engine.spoken, hasLength(4));
    });

    test('pause/resume：引擎支持时走原生暂�?, () async {
      await controller.start(locked: false);
      await controller.pause();
      expect(controller.state, TtsState.paused);
      expect(engine.pauseCalled, isTrue);

      // 暂停期间的完成回调被丢弃（不推进）�?      await engine.completeCurrent();
      expect(controller.utteranceIndex, 0);

      await controller.resume();
      expect(controller.state, TtsState.playing);
      expect(engine.resumeCalled, isTrue);
      expect(engine.spoken, hasLength(1), reason: '原生暂停恢复不重�?);
    });

    test('pause/resume：平台不支持暂停时降级为重读当前�?, () async {
      engine.supportsPause = false;
      await controller.start(locked: false);
      await controller.pause();
      expect(controller.state, TtsState.paused);
      expect(engine.pauseCalled, isTrue);

      final spokenBefore = engine.spoken.length;
      await controller.resume();
      expect(controller.state, TtsState.playing);
      expect(engine.spoken.length, spokenBefore + 1,
          reason: '降级语义：恢复时重读当前�?);
      expect(engine.spoken.last.text, '第一�?启程');
      expect(engine.resumeCalled, isFalse, reason: '不支持暂停就没有原生 resume');
    });

    test('stop 回到 idle 并清空进度；重复 stop 幂等', () async {
      await controller.start(locked: false);
      await engine.completeCurrent();
      await controller.stop();

      expect(controller.state, TtsState.idle);
      expect(controller.progress, isNull);
      expect(engine.stopCalled, 1);

      await controller.stop();
      expect(engine.stopCalled, 1, reason: 'stop 幂等');
    });

    test('seekToUtterance 跳段朗读；越界被忽略', () async {
      await controller.start(locked: false);
      await controller.seekToUtterance(3);

      expect(controller.progress?.blockIndex, 3);
      expect(controller.progress?.anchor, 3);
      expect(engine.spoken.last.text, '山路蜿蜒，他在暮色里看见了城墙�?);

      final before = engine.spoken.length;
      await controller.seekToUtterance(99);
      await controller.seekToUtterance(-1);
      expect(engine.spoken.length, before, reason: '越界不产生朗�?);
    });

    test('锁定章拒绝朗读：抛错、引擎零调用、状�?error', () async {
      await expectLater(
        controller.start(locked: true),
        throwsA(isA<StateError>()),
      );

      expect(controller.state, TtsState.error);
      expect(engine.spoken, isEmpty, reason: '锁定章引擎零调用');
      expect(controller.progress, isNull);
    });

    test('空块序列（未渲染正文的锁定章兜底）：start 直接 completed', () async {
      final empty = TtsController(
        engine: FakeTtsEngine(),
        blocks: const <ReaderBlock>[],
      );
      await empty.start(locked: false);
      expect(empty.state, TtsState.completed);
    });

    test('引擎错误进入 error �?, () async {
      await controller.start(locked: false);
      engine.failCurrent('合成失败');
      expect(controller.state, TtsState.error);
    });

    test('start �?playing/paused 时是幂等空操�?, () async {
      await controller.start(locked: false);
      await engine.completeCurrent();
      await controller.start(locked: false);
      expect(controller.utteranceIndex, 1, reason: '重复 start 不重置进�?);
      expect(engine.spoken, hasLength(2));
    });
  });
}

/// 可编程假引擎：记录朗读序列，手动触发完成/错误�?class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({this.supportsPause = true});

  @override
  bool supportsPause;

  @override
  set callbacks(TtsEngineCallbacks value) => _callbacks = value;

  TtsEngineCallbacks? _callbacks;

  final List<TtsUtterance> spoken = <TtsUtterance>[];
  bool pauseCalled = false;
  bool resumeCalled = false;
  int stopCalled = 0;

  /// 当前在朗读的 utterance（最后一�?speak 的）�?  TtsUtterance? get current => spoken.isEmpty ? null : spoken.last;

  /// 模拟引擎播完当前 utterance�?  Future<void> completeCurrent() async {
    final current = this.current;
    if (current == null) return;
    _callbacks?.onComplete?.call(current.text);
    // onComplete 里控制器同步推进并调用下一�?speak（异步），让出事件循环�?    await Future<void>.delayed(Duration.zero);
  }

  /// 模拟引擎错误�?  void failCurrent(String message) {
    _callbacks?.onError?.call(StateError(message));
  }

  @override
  Future<void> speak(TtsUtterance utterance) async {
    spoken.add(utterance);
  }

  @override
  Future<bool> pause() async {
    pauseCalled = true;
    return supportsPause;
  }

  @override
  Future<void> resume() async {
    resumeCalled = true;
  }

  @override
  Future<void> stop() async {
    stopCalled += 1;
  }

  // D48 语音选项：合同层默认实现为空，这里显式落地以保持 implements 完整�?  // 需要记录语�?音色的替身见 d48_tts_settings_test.dart �?_VoiceEngine�?  @override
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {}

  @override
  Future<List<TtsVoiceInfo>> availableVoices() async => const <TtsVoiceInfo>[];
}

