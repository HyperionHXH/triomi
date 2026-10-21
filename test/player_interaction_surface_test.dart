import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/player/player_interaction_surface.dart';

class _PlayerHarness extends StatefulWidget {
  const _PlayerHarness({super.key});

  @override
  State<_PlayerHarness> createState() => _PlayerHarnessState();
}

class _PlayerHarnessState extends State<_PlayerHarness> {
  Duration position = const Duration(seconds: 120);
  Duration duration = const Duration(minutes: 10);
  Duration? previewOrigin;
  double volume = .5;
  double brightness = .5;
  bool enabled = true;
  int session = 0;
  final seeks = <Duration>[];
  final holds = <bool>[];
  int saves = 0;
  int toggles = 0;
  final sliderFocus = FocusNode();
  final buttonFocus = FocusNode();
  final textFocus = FocusNode();

  void update(VoidCallback action) => setState(action);

  @override
  void dispose() {
    sliderFocus.dispose();
    buttonFocus.dispose();
    textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          height: 400,
          child: PlayerInteractionSurface(
            enabled: enabled,
            session: session,
            position: position,
            duration: duration,
            volume: volume,
            brightness: brightness,
            brightnessEnabled: true,
            holdSpeed: 2.5,
            onTap: () {},
            onTogglePlay: () => toggles++,
            onSeek: (target) => setState(() {
              seeks.add(target);
              position = target;
            }),
            onScrubStart: () => previewOrigin = position,
            onScrubUpdate: (target) => setState(() => position = target),
            onScrubEnd: (target) => setState(() {
              if (target == null) {
                position = previewOrigin ?? position;
              } else {
                seeks.add(target);
                position = target;
              }
              previewOrigin = null;
            }),
            onVolumeChanged: (value) => setState(() => volume = value),
            onVolumeEnd: () => saves++,
            onBrightnessChanged: (value) => setState(() => brightness = value),
            onHoldChanged: holds.add,
            controls: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 90,
                child: Column(
                  children: [
                    Slider(
                      focusNode: sliderFocus,
                      value: position.inSeconds.toDouble(),
                      max: duration.inSeconds.toDouble(),
                      onChanged: (_) =>
                          throw StateError('Slider consumed arrow'),
                    ),
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          TextButton(
                            focusNode: buttonFocus,
                            onPressed: () {},
                            child: const Text('Control'),
                          ),
                          Expanded(child: TextField(focusNode: textFocus)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'blank drag previews full-width 180s and commits once on release',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('player-blank-input')),
      );
      final drag = await tester.startGesture(
        area.center - const Offset(180, 0),
      );
      await drag.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(key.currentState!.seeks, isEmpty);
      expect(find.byKey(const ValueKey('player-seek-hud')), findsOneWidget);
      expect(find.textContaining('+36 秒'), findsOneWidget);
      expect(key.currentState!.position, const Duration(seconds: 156));
      await drag.up();
      await tester.pump();
      expect(key.currentState!.seeks, [const Duration(seconds: 156)]);
      expect(key.currentState!.toggles, 0);
      await tester.pump(const Duration(seconds: 2));
    },
  );
  testWidgets(
    'drag cancellation rolls back and both bounds clamp without a seek',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('player-blank-input')),
      );
      var drag = await tester.startGesture(area.center);
      await drag.moveBy(const Offset(-600, 0));
      await tester.pump();
      expect(key.currentState!.position, Duration.zero);
      expect(key.currentState!.seeks, isEmpty);
      await drag.cancel();
      await tester.pump();
      expect(key.currentState!.position, const Duration(seconds: 120));
      expect(key.currentState!.seeks, isEmpty);
      key.currentState!.update(
        () => key.currentState!.position = const Duration(seconds: 590),
      );
      await tester.pump();
      drag = await tester.startGesture(area.center);
      await drag.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(key.currentState!.position, const Duration(minutes: 10));
      await drag.up();
      await tester.pump();
      expect(key.currentState!.seeks, [const Duration(minutes: 10)]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'both halves show actual level and progress then persist app volume',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('player-blank-input')),
      );
      var drag = await tester.startGesture(area.center - const Offset(60, 0));
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(key.currentState!.brightness, closeTo(.7, .001));
      expect(find.text('亮度 70%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(.7, .001),
      );
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('亮度 70%'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('player-level-hud')), findsNothing);
      drag = await tester.startGesture(area.center + const Offset(60, 0));
      await drag.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(key.currentState!.volume, closeTo(.3, .001));
      expect(find.text('音量 30%'), findsOneWidget);
      await drag.up();
      await tester.pump();
      expect(key.currentState!.saves, 1);
      expect(key.currentState!.seeks, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  for (final direction in [
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  ]) {
    testWidgets(
      '${direction.keyLabel} wins over focused slider, ramps and resets',
      (tester) async {
        final key = GlobalKey<_PlayerHarnessState>();
        await tester.pumpWidget(_PlayerHarness(key: key));
        await tester.pump();
        key.currentState!.update(
          () => key.currentState!.position = const Duration(seconds: 300),
        );
        key.currentState!.sliderFocus.requestFocus();
        await tester.pump();
        final sign = direction == LogicalKeyboardKey.arrowLeft ? -1 : 1;
        await tester.sendKeyDownEvent(direction);
        await tester.pump();
        expect(key.currentState!.position, Duration(seconds: 300 + sign * 15));
        await tester.sendKeyRepeatEvent(direction); // Throttled native repeat.
        expect(key.currentState!.seeks, hasLength(1));
        var expected = 300 + sign * 15;
        for (final step in [20, 25, 30, 30]) {
          await tester.pump(const Duration(milliseconds: 200));
          await tester.sendKeyRepeatEvent(direction);
          await tester.pump();
          expected += sign * step;
          expect(key.currentState!.position, Duration(seconds: expected));
        }
        await tester.sendKeyUpEvent(direction);
        await tester.pump();
        key.currentState!.buttonFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(direction);
        await tester.pump();
        expect(
          key.currentState!.position,
          Duration(seconds: expected + sign * 15),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'volume arrows are app steps with HUD and text fields keep their keys',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      key.currentState!.sliderFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(key.currentState!.volume, closeTo(.6, .001));
      expect(find.text('音量 60%'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(key.currentState!.volume, closeTo(.5, .001));
      expect(key.currentState!.saves, 2);
      key.currentState!.textFocus.requestFocus();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'text');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(key.currentState!.seeks, isEmpty);
      expect(key.currentState!.saves, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'controls intercept drags and disabled surface ignores player keys',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      await tester.drag(find.text('Control'), const Offset(90, 0));
      expect(key.currentState!.seeks, isEmpty);
      expect(key.currentState!.previewOrigin, isNull);
      key.currentState!.buttonFocus.requestFocus();
      key.currentState!.update(() => key.currentState!.enabled = false);
      await tester.pump();
      expect(find.byKey(const ValueKey('player-blank-input')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(key.currentState!.seeks, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'mouse hold restores on release, pointer cancel and route loss without playback',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('player-blank-input')),
      );
      var mouse = await tester.startGesture(
        area.center,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(key.currentState!.holds, [true]);
      final speedHud = tester.getRect(
        find.byKey(const ValueKey('player-speed-hud')),
      );
      expect(speedHud.width, lessThan(150));
      expect(speedHud.height, lessThan(40));
      expect(speedHud.center.dx, closeTo(area.center.dx, 1));
      expect(speedHud.top, lessThan(area.top + 48));
      expect(find.text('2.5x'), findsOneWidget);
      await mouse.up();
      await tester.pump();
      expect(key.currentState!.holds, [true, false]);
      mouse = await tester.startGesture(
        area.center,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      await mouse.cancel();
      await tester.pump();
      expect(key.currentState!.holds, [true, false, true, false]);
      mouse = await tester.startGesture(
        area.center,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      final context = tester.element(find.byType(PlayerInteractionSurface));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('Dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.holds, [true, false, true, false, true, false]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(key.currentState!.seeks, isEmpty);
      expect(key.currentState!.toggles, 0);
      await mouse.up();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('volume keys cannot discard an active seek preview', (
    tester,
  ) async {
    final key = GlobalKey<_PlayerHarnessState>();
    await tester.pumpWidget(_PlayerHarness(key: key));
    await tester.pump();
    final area = tester.getRect(
      find.byKey(const ValueKey('player-blank-input')),
    );
    final drag = await tester.startGesture(area.center);
    await drag.moveBy(const Offset(120, 0));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(key.currentState!.seeks, [const Duration(seconds: 156)]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
    'session and lifecycle loss cancel preview and held repeat state',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('player-blank-input')),
      );
      final drag = await tester.startGesture(area.center);
      await drag.moveBy(const Offset(90, 0));
      await tester.pump();
      key.currentState!.update(() => key.currentState!.session++);
      await tester.pump();
      await tester.pump();
      expect(key.currentState!.position, const Duration(seconds: 120));
      expect(find.byKey(const ValueKey('player-seek-hud')), findsNothing);
      await drag.up();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(key.currentState!.seeks, [const Duration(seconds: 135)]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      expect(key.currentState!.seeks, hasLength(1));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(key.currentState!.seeks.last, const Duration(seconds: 150));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'double taps keep outer-quarter fifteen-second seek and middle pause',
    (tester) async {
      final key = GlobalKey<_PlayerHarnessState>();
      await tester.pumpWidget(_PlayerHarness(key: key));
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('player-blank-input')),
      );
      for (final offset in [-240.0, 240.0, 0.0]) {
        final point = area.center + Offset(offset, 0);
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 350));
      }
      expect(key.currentState!.seeks, [
        const Duration(seconds: 105),
        const Duration(seconds: 120),
      ]);
      expect(key.currentState!.toggles, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('focus loss stops repeats and hold without waiting for key-up', (
    tester,
  ) async {
    final key = GlobalKey<_PlayerHarnessState>();
    await tester.pumpWidget(_PlayerHarness(key: key));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    expect(key.currentState!.seeks, [const Duration(seconds: 135)]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    key.currentState!.buttonFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.seeks.last, const Duration(seconds: 150));
    final area = tester.getRect(
      find.byKey(const ValueKey('player-blank-input')),
    );
    final pointer = await tester.startGesture(area.center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
    expect(key.currentState!.holds, [true]);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(key.currentState!.holds, [true, false]);
    await pointer.up();
    await tester.pumpWidget(const SizedBox());
  });
}
