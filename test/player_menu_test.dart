import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/player/data/player_settings.dart';
import 'package:triomi/features/player/player_menu.dart';

class _MenuHarness extends StatefulWidget {
  const _MenuHarness({
    super.key,
    this.onSave,
    this.onAction,
    this.textScale = 1,
    this.padding = EdgeInsets.zero,
    this.features = true,
    this.onVolume,
    this.volumeEnabled = true,
    this.volumeStatus,
  });

  final Future<void> Function(PlayerSettings)? onSave;
  final Future<void> Function(PlayerMenuAction)? onAction;
  final double textScale;
  final EdgeInsets padding;
  final bool features;
  final Future<double> Function(double)? onVolume;
  final bool volumeEnabled;
  final String? volumeStatus;

  @override
  State<_MenuHarness> createState() => _MenuHarnessState();
}

class _MenuHarnessState extends State<_MenuHarness> {
  PlayerSettings settings = const PlayerSettings();
  final visibility = <bool>[];
  final actions = <PlayerMenuAction>[];
  int outsideTaps = 0;

  void reportDeviceVolume(double value) {
    setState(() => settings = settings.copyWith(volume: value));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(widget.textScale),
          padding: widget.padding,
        ),
        child: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('playback-surface'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => outsideTaps++),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: PlayerMenu(
                    settings: settings,
                    nativeVideo: widget.features,
                    onVolumeChanged: widget.onVolume,
                    volumeEnabled: widget.volumeEnabled,
                    volumeStatus: widget.volumeStatus,
                    lineName: widget.features
                        ? List.filled(30, 'source').join()
                        : null,
                    danmakuEnabled: widget.features,
                    onVisibilityChanged: visibility.add,
                    onSettingsChanged: (value) async {
                      await widget.onSave?.call(value);
                      if (mounted) setState(() => settings = value);
                    },
                    onAction: (action) async {
                      actions.add(action);
                      await widget.onAction?.call(action);
                    },
                    builder: (context, toggle) => IconButton(
                      key: const ValueKey('player-menu-trigger'),
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: toggle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-menu-trigger')));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String id) async {
  final finder = find.byKey(ValueKey('player-menu-$id'));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform native menu exposes PiP', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final key = GlobalKey<_MenuHarnessState>();
      await tester.pumpWidget(_MenuHarness(key: key));
      await _open(tester);
      await _tap(tester, 'action-pip');
      expect(key.currentState!.actions, [PlayerMenuAction.pip]);
      expect(key.currentState!.visibility, [true, false]);
      await _open(tester);
      await _tap(tester, 'info');
      expect(
        find.textContaining(
          platform == TargetPlatform.iOS ? '系统管理预载' : '持续预载本集 · 有界内存',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
    'desktop volume keeps continuous app gain through normal settings callback',
    (tester) async {
      final key = GlobalKey<_MenuHarnessState>();
      final saved = <PlayerSettings>[];
      await tester.pumpWidget(
        _MenuHarness(
          key: key,
          features: false,
          onSave: (settings) async {
            saved.add(settings);
          },
        ),
      );
      await _open(tester);
      await _tap(tester, 'volume');
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('player-menu-volume-slider')),
      );
      slider.onChanged!(.46);
      slider.onChangeEnd!(.46);
      await tester.pumpAndSettle();
      expect(saved.single.volume, .46);
      expect(key.currentState!.settings.volume, .46);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _open(tester);
      await _tap(tester, 'volume');
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('player-menu-volume-slider')),
            )
            .value,
        .46,
      );
    },
  );

  testWidgets(
    'device menu replaces optimistic slider with snapped readback without saving desktop gain',
    (tester) async {
      final pending = Completer<double>();
      var saves = 0;
      var requested = 0.0;
      await tester.pumpWidget(
        _MenuHarness(
          onSave: (_) async {
            saves++;
          },
          onVolume: (value) {
            requested = value;
            return pending.future;
          },
        ),
      );
      await _open(tester);
      await _tap(tester, 'volume');
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('player-menu-volume-slider')),
      );
      slider.onChanged!(.46);
      slider.onChangeEnd!(.46);
      await tester.pump();
      expect(requested, .46);
      pending.complete(.5);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('player-menu-volume-slider')),
            )
            .value,
        .5,
      );
      expect(find.text('50%'), findsOneWidget);
      expect(saves, 0);
    },
  );

  testWidgets(
    'fixed device reports the limitation and disables its volume slider',
    (tester) async {
      await tester.pumpWidget(
        const _MenuHarness(volumeEnabled: false, volumeStatus: '此设备使用固定音量'),
      );
      await _open(tester);
      await _tap(tester, 'volume');
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('player-menu-volume-slider')),
      );
      expect(slider.onChanged, isNull);
      expect(slider.onChangeEnd, isNull);
      expect(find.text('此设备使用固定音量'), findsOneWidget);
    },
  );

  testWidgets(
    'settings apply immediately and retain selections after reopening',
    (tester) async {
      final key = GlobalKey<_MenuHarnessState>();
      final applied = <PlayerSettings>[];
      await tester.pumpWidget(
        _MenuHarness(
          key: key,
          onSave: (value) async {
            applied.add(value);
          },
        ),
      );
      await _open(tester);
      await _tap(tester, 'speed');
      await _tap(tester, 'speed-1.5');
      expect(key.currentState!.settings.speed, 1.5);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('player-menu-speed-1.5')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.selected == true,
          ),
        ),
        findsOneWidget,
      );
      await _tap(tester, 'back');
      await _tap(tester, 'ratio');
      await _tap(tester, 'ratio-ratio4x3');
      expect(key.currentState!.settings.aspectRatio, VideoAspectRatio.ratio4x3);
      await _tap(tester, 'back');
      await _tap(tester, 'preferences');
      await _tap(tester, 'auto-next');
      await _tap(tester, 'background-audio');
      await _tap(tester, 'hold-speed');
      await _tap(tester, 'hold-speed-2.5');
      expect(key.currentState!.settings.autoNext, isFalse);
      expect(key.currentState!.settings.backgroundAudio, isTrue);
      expect(key.currentState!.settings.holdSpeed, 2.5);
      await _tap(tester, 'back');
      await _tap(tester, 'back');
      await _tap(tester, 'volume');
      final slider = find.byKey(const ValueKey('player-menu-volume-slider'));
      await tester.drag(slider, const Offset(-80, 0));
      await tester.pumpAndSettle();
      expect(key.currentState!.settings.volume, lessThan(1));
      expect(applied, hasLength(6));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _open(tester);
      await _tap(tester, 'speed');
      expect(key.currentState!.settings.speed, 1.5);
      expect(key.currentState!.visibility, [true, false, true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outside taps dismiss without toggling playback and system back closes menu',
    (tester) async {
      final key = GlobalKey<_MenuHarnessState>();
      await tester.pumpWidget(_MenuHarness(key: key));
      await _open(tester);
      await tester.tapAt(const Offset(12, 550));
      await tester.pumpAndSettle();
      expect(key.currentState!.visibility, [true, false]);
      expect(key.currentState!.outsideTaps, 0);
      await tester.tapAt(const Offset(12, 550));
      await tester.pumpAndSettle();
      expect(key.currentState!.outsideTaps, 1);
      await _open(tester);
      await _tap(tester, 'preferences');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(key.currentState!.visibility, [true, false, true, false]);
      expect(find.byKey(const ValueKey('player-menu-trigger')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('device updates do not rewind an active volume drag', (tester) async {
    final key = GlobalKey<_MenuHarnessState>();
    final writes = <double>[];
    await tester.pumpWidget(_MenuHarness(
      key: key,
      onVolume: (value) async {
        writes.add(value);
        final actual = (value * 10).round() / 10;
        key.currentState!.reportDeviceVolume(actual);
        return actual;
      },
    ));
    key.currentState!.reportDeviceVolume(.3);
    await tester.pump();
    await _open(tester);
    await _tap(tester, 'volume');
    final slider = find.byKey(const ValueKey('player-menu-volume-slider'));
    final bounds = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(bounds.left + bounds.width * .3, bounds.center.dy),
    );
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    final draft = tester.widget<Slider>(slider).value;
    expect(draft, greaterThan(.3));
    key.currentState!.reportDeviceVolume(.3);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<Slider>(slider).value, draft);
    expect(writes, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(writes.single, closeTo(draft, .001));
    expect(tester.widget<Slider>(slider).value, (draft * 10).round() / 10);
    key.currentState!.reportDeviceVolume(.8);
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, .8);
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 240),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'menu stays scrollable inside safe bounds at $size scale $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const padding = EdgeInsets.fromLTRB(12, 24, 16, 20);
          await tester.pumpWidget(
            _MenuHarness(textScale: scale, padding: padding),
          );
          await _open(tester);
          final scroll = find
              .ancestor(
                of: find.byKey(const ValueKey('player-menu-speed')),
                matching: find.byType(SingleChildScrollView),
              )
              .first;
          final rect = tester.getRect(scroll);
          expect(rect.left, greaterThanOrEqualTo(padding.left));
          expect(rect.right, lessThanOrEqualTo(size.width - padding.right));
          expect(rect.top, greaterThanOrEqualTo(padding.top));
          expect(rect.bottom, lessThanOrEqualTo(size.height - padding.bottom));
          expect(rect.width, lessThanOrEqualTo(296));
          await _tap(tester, 'info');
          await _tap(tester, 'back');
          await _tap(tester, 'speed');
          await _tap(tester, 'speed-3.0');
          await _tap(tester, 'back');
          await _tap(tester, 'ratio');
          await _tap(tester, 'ratio-ratio1x1');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'optional actions follow capabilities and close before asynchronous work ends',
    (tester) async {
      final key = GlobalKey<_MenuHarnessState>();
      final action = Completer<void>();
      await tester.pumpWidget(
        _MenuHarness(key: key, features: false, onAction: (_) => action.future),
      );
      await _open(tester);
      expect(find.byKey(const ValueKey('player-menu-danmaku')), findsNothing);
      expect(
        find.byKey(const ValueKey('player-menu-action-line')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('player-menu-action-pip')),
        findsNothing,
      );
      await _tap(tester, 'action-retry');
      expect(key.currentState!.actions, [PlayerMenuAction.retry]);
      expect(key.currentState!.visibility, [true, false]);
      await tester.pumpWidget(const SizedBox());
      action.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('danmaku actions retain their distinct callbacks', (
    tester,
  ) async {
    final key = GlobalKey<_MenuHarnessState>();
    await tester.pumpWidget(_MenuHarness(key: key));
    for (final action in [
      PlayerMenuAction.toggleDanmaku,
      PlayerMenuAction.danmakuSettings,
      PlayerMenuAction.danmakuSources,
    ]) {
      await _open(tester);
      await _tap(tester, 'danmaku');
      await _tap(
        tester,
        action == PlayerMenuAction.toggleDanmaku
            ? 'danmaku-toggle'
            : 'action-${action.name}',
      );
      expect(key.currentState!.actions.last, action);
      expect(key.currentState!.visibility.last, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing closes the anchor and a fresh menu remains usable', (
    tester,
  ) async {
    final key = GlobalKey<_MenuHarnessState>();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_MenuHarness(key: key));
    await _open(tester);
    await _tap(tester, 'preferences');
    tester.view.physicalSize = const Size(640, 240);
    await tester.pumpAndSettle();
    expect(key.currentState!.visibility, [true, false]);
    await _open(tester);
    await _tap(tester, 'speed');
    await _tap(tester, 'speed-1.25');
    expect(key.currentState!.settings.speed, 1.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed setting is restored and pending setting can finish after disposal',
    (tester) async {
      final key = GlobalKey<_MenuHarnessState>();
      var fail = true;
      final pending = Completer<void>();
      await tester.pumpWidget(
        _MenuHarness(
          key: key,
          onSave: (_) async {
            if (fail) throw StateError('save unavailable');
            await pending.future;
          },
        ),
      );
      await _open(tester);
      await _tap(tester, 'speed');
      await _tap(tester, 'speed-1.5');
      expect(key.currentState!.settings.speed, 1);
      expect(tester.takeException(), isNull);
      fail = false;
      await tester.tap(find.byKey(const ValueKey('player-menu-speed-1.5')));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
