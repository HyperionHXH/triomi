import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/novel/reader/novel_blocks.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';

import 'tts_test_fakes.dart';

List<ReaderBlock> sampleBlocks() => const <ReaderBlock>[
      HeadingBlock('Chapter one'),
      ParagraphBlock('A short paragraph.'),
      IllustrationBlock('https://example.com/image.png'),
      ParagraphBlock('The final paragraph.'),
    ];

void main() {
  group('TtsPlan', () {
    test('creates heading, paragraph, placeholder and paragraph utterances', () {
      final plan = TtsPlan.of(sampleBlocks());
      expect(plan.utterances, hasLength(4));
      expect(plan.utterances[0].blockIndex, 0);
      expect(plan.utterances[0].pauseAfterMs, greaterThan(0));
      expect(plan.utterances[2].isPlaceholder, isTrue);
      expect(plan.utterances[2].blockIndex, 2);
    });

    test('splits long text while preserving the block anchor', () {
      final plan = TtsPlan.of(
        const <ReaderBlock>[ParagraphBlock('abcdefghij klmnopqrst uvwxyz')],
        maxCharacters: 10,
      );
      expect(plan.utterances, hasLength(3));
      expect(plan.utterances.every((item) => item.text.length <= 10), isTrue);
      expect(plan.utterances.map((item) => item.blockIndex), everyElement(0));
    });
  });

  group('TtsController', () {
    late FakeTtsEngine engine;
    late TtsController controller;

    setUp(() {
      engine = FakeTtsEngine();
      controller = TtsController(engine: engine, blocks: sampleBlocks());
    });

    test('starts and advances on completion', () async {
      await controller.start(locked: false);
      expect(controller.state, TtsState.playing);
      expect(controller.progress?.anchor, 0);
      await engine.completeCurrent();
      expect(controller.progress?.anchor, 1);
    });

    test('placeholder does not advance the reading anchor', () async {
      await controller.start(locked: false);
      await engine.completeCurrent();
      await engine.completeCurrent();
      expect(controller.progress?.blockIndex, 2);
      expect(controller.progress?.anchor, 1);
      await engine.completeCurrent();
      expect(controller.progress?.anchor, 3);
    });

    test('pause and resume use the engine contract', () async {
      await controller.start(locked: false);
      await controller.pause();
      expect(controller.state, TtsState.paused);
      await controller.resume();
      expect(controller.state, TtsState.playing);
      expect(engine.pauseCalled, isTrue);
      expect(engine.resumeCalled, isTrue);
    });

    test('unsupported pause stops and repeats the current utterance', () async {
      engine.supportsPause = false;
      await controller.start(locked: false);
      await controller.pause();
      final count = engine.spoken.length;
      await controller.resume();
      expect(engine.spoken.length, count + 1);
      expect(engine.stopCalled, greaterThan(0));
    });

    test('stop is idempotent and clears progress', () async {
      await controller.start(locked: false);
      await controller.stop();
      await controller.stop();
      expect(controller.state, TtsState.idle);
      expect(controller.progress, isNull);
      expect(engine.stopCalled, 1);
    });

    test('locked chapters never call the engine', () async {
      await expectLater(controller.start(locked: true), throwsStateError);
      expect(controller.state, TtsState.error);
      expect(engine.spoken, isEmpty);
    });
  });
}
