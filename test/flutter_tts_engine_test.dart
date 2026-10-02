import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/novel/reader/novel_blocks.dart';
import 'package:triomi/features/novel/tts/flutter_tts_engine.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  final pending = <Completer<int>>[];
  final calls = <MethodCall>[];
  setUp(() {
    pending.clear();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'speak') {
            final completion = Completer<int>();
            pending.add(completion);
            return completion.future;
          }
          return 1;
        });
  });
  tearDown(() {
    for (final completion in pending) {
      if (!completion.isCompleted) completion.complete(0);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('real plugin Future returns the issued token with platform speech arguments', () async {
    final controller = TtsController(
      engine: FlutterTtsEngine(),
      blocks: const [ParagraphBlock('重复'), ParagraphBlock('重复')],
    );
    await controller.start(locked: false);
    await flush();
    expect(pending, hasLength(1));
    expect(
      calls.firstWhere((c) => c.method == 'awaitSpeakCompletion').arguments,
      true,
    );
    final arguments = calls.firstWhere((c) => c.method == 'speak').arguments;
    if (arguments is Map) {
      expect(arguments['focus'], true);
    } else {
      expect(arguments, '重复');
    }
    pending.first.complete(1);
    await flush();
    expect(controller.utteranceIndex, 1);
    expect(pending, hasLength(2));
    pending.last.complete(1);
    await flush();
    expect(controller.state, TtsState.completed);
    controller.dispose();
  });

  test(
    'seek discards an old same-text completion without guessing its token',
    () async {
      final controller = TtsController(
        engine: FlutterTtsEngine(),
        blocks: const [ParagraphBlock('重复'), ParagraphBlock('重复')],
      );
      await controller.start(locked: false);
      await flush();
      await controller.seekToUtterance(1);
      await flush();
      pending.first.complete(1);
      await flush();
      expect(controller.state, TtsState.playing);
      pending.last.complete(1);
      await flush();
      expect(controller.state, TtsState.completed);
      controller.dispose();
    },
  );

  test(
    'pause stops synthesis and resume repeats the current paragraph',
    () async {
      final controller = TtsController(
        engine: FlutterTtsEngine(),
        blocks: const [ParagraphBlock('正文')],
      );
      await controller.start(locked: false);
      await flush();
      await controller.pause();
      expect(calls.where((c) => c.method == 'stop'), isNotEmpty);
      await controller.resume();
      await flush();
      pending.first.complete(1);
      await flush();
      expect(controller.state, TtsState.playing);
      pending.last.complete(1);
      await flush();
      expect(controller.state, TtsState.completed);
      controller.dispose();
    },
  );

  test('plugin refusal produces an error state; locked chapters never initialize it', () async {
    final locked = TtsController(
      engine: FlutterTtsEngine(),
      blocks: const [ParagraphBlock('锁定')],
    );
    await expectLater(locked.start(locked: true), throwsStateError);
    expect(calls, isEmpty);
    locked.dispose();
    final controller = TtsController(
      engine: FlutterTtsEngine(),
      blocks: const [ParagraphBlock('正文')],
    );
    await controller.start(locked: false);
    await flush();
    pending.single.complete(0);
    await flush();
    expect(controller.state, TtsState.error);
    controller.dispose();
  });
}
