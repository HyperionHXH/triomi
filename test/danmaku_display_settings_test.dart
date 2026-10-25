import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/text/zh_converter.dart';
import 'package:triomi/features/player/danmaku_settings_page.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/data/danmaku_settings.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';

import 'fixtures/fake_preferences.dart';

DanmakuController configured({
  DanmakuSettings settings = const DanmakuSettings(),
  int Function()? clock,
  ZhConverter? converter,
  double height = 240,
}) =>
    DanmakuController(
        settings: settings,
        wallClockMs: clock,
        converter: converter,
      )
      ..height = height
      ..configure(
        width: 400,
        laneHeight: 24,
        style: const TextStyle(fontSize: 16),
      );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy keys survive and malformed backup values normalize safely',
    () async {
      final preferences = memoryPreferences();
      await preferences.importAll({
        'danmaku.fontScale': 1.3,
        'danmaku.speedScale': 2,
        'danmaku.blockedWords': ['剧透'],
        'danmaku.blockedUsers': ['u1'],
        'danmaku.opacity': double.nan,
        'danmaku.area': -1,
        'danmaku.fontWeight': 99,
        'danmaku.fontSize': 900,
        'danmaku.lineHeight': double.infinity,
        'danmaku.maxActive': 100000,
        'danmaku.conversion': 'unknown',
        'danmaku.readonly.bindings': 'owned-by-session',
      });
      final settings = DanmakuSettings.load(preferences);
      expect(settings.fontScale, 1.3);
      expect(settings.scrollDurationMs, 4500);
      expect(settings.fontSize, 48);
      expect(settings.fontWeight, 9);
      expect(settings.opacity, 0.9);
      expect(settings.area, 0);
      expect(settings.lineHeight, 1.6);
      expect(settings.maxActive, 300);
      expect(settings.conversion, ZhConversionMode.off);
      await settings.save(preferences);
      expect(
        preferences.get<String>('danmaku.readonly.bindings'),
        'owned-by-session',
      );
      expect(DanmakuSettings.load(preferences).blockedWords, ['剧透']);
      expect(DanmakuSettings.load(preferences).blockedUsers, ['u1']);
    },
  );

  test(
    'display boundaries and complete roundtrip retain every toggle',
    () async {
      final settings = const DanmakuSettings().copyWith(
        opacity: -1,
        area: 2,
        durationSeconds: 100,
        fontSize: 1,
        fontWeight: 0,
        lineHeight: -1,
        outlineWidth: 8,
        followVideoRate: false,
        showColor: false,
        outline: false,
        showTop: false,
        showBottom: false,
        showScroll: false,
        massive: true,
        maxActive: 400,
        mergeDuplicates: true,
        conversion: ZhConversionMode.t2s,
        shieldRules: const [DanmakuShieldRule(text: '^剧透', isRegex: true)],
      );
      final preferences = memoryPreferences();
      await settings.save(preferences);
      final restored = DanmakuSettings.load(preferences);
      expect(restored.toJson(), settings.toJson());
      expect(restored.opacity, 0.1);
      expect(restored.area, 1);
      expect(restored.durationSeconds, 16);
      expect(restored.fontSize, 10);
      expect(restored.fontWeight, 1);
      expect(restored.lineHeight, 0);
      expect(restored.outlineWidth, 3);
      expect(restored.maxActive, 300);
      expect(
        const DanmakuSettings().copyWith(durationSeconds: 0).durationSeconds,
        2,
      );
      expect(const DanmakuSettings().copyWith(fontSize: 99).fontSize, 48);
    },
  );

  test('safe regex validation rejects expensive expressions and invalid imports atomically', () {
    for (final pattern in [
      r'(a+)+$',
      r'a|b',
      r'a.*b.*c',
      r'(?=a)',
      r'(a)\1',
      r'a{1,}',
      '[',
    ]) {
      expect(
        DanmakuShieldRule(text: pattern, isRegex: true).validationError,
        isNotNull,
        reason: pattern,
      );
    }
    const settings = DanmakuSettings(
      shieldRules: [
        DanmakuShieldRule(text: r'^剧透[0-9]{1,4}$', isRegex: true),
        DanmakuShieldRule(text: '广告', enabled: false),
      ],
    );
    expect(settings.filters('剧透12'), isTrue);
    expect(settings.filters('广告'), isFalse);
    expect(
      settings
          .copyWith(
            shieldRules: [settings.shieldRules.last.copyWith(enabled: true)],
          )
          .filters('广告'),
      isTrue,
    );
    expect(settings.filters('剧透文字'), isFalse);
    expect(settings.filters(List.filled(513, 'a').join()), isTrue);
    expect(
      () => settings.importShieldRules(r'/(a+)+$/'),
      throwsFormatException,
    );
    expect(settings.shieldRules, hasLength(2));
    final imported = settings.importShieldRules(
      '关键词\n'
      r'/^spam[0-9]+$/',
    );
    expect(imported.filters('关键词内容'), isTrue);
    expect(imported.filters('spam123'), isTrue);
    final exported = imported.exportShieldRules();
    final restored = const DanmakuSettings().importShieldRules(exported);
    expect(
      restored.shieldRules.map((r) => r.toJson()).toList(),
      imported.shieldRules.map((r) => r.toJson()).toList(),
    );
    final unsafeBackup = DanmakuSettings.fromJson({
      'danmaku.shieldRules': [
        const DanmakuShieldRule(text: r'(a+)+$', isRegex: true).toJson(),
      ],
    });
    expect(unsafeBackup.shieldRules.single.enabled, isFalse);
    expect(unsafeBackup.filters('aaaaaaa'), isFalse);
  });

  test('restore defaults preserves keywords, users, disabled rules and legacy keys', () async {
    const settings = DanmakuSettings(
      enabled: false,
      area: 0.5,
      massive: true,
      blockedWords: ['剧透'],
      blockedUsers: ['public-user'],
      shieldRules: [
        DanmakuShieldRule(text: '^spoiler', isRegex: true, enabled: false),
      ],
    );
    final preferences = memoryPreferences();
    await settings.save(preferences);
    final restored = settings.restoreDefaults();
    await restored.save(preferences);
    final loaded = DanmakuSettings.load(preferences);
    expect(loaded.enabled, isTrue);
    expect(loaded.area, 1);
    expect(loaded.massive, isFalse);
    expect(loaded.blockedWords, settings.blockedWords);
    expect(loaded.blockedUsers, settings.blockedUsers);
    expect(loaded.shieldRules.single.enabled, isFalse);
    expect(loaded.filters('anything', user: 'public-user'), isTrue);
    expect(
      jsonEncode(preferences.exportAll()),
      contains('danmaku.blockedWords'),
    );
  });

  test('follow-rate changes animation only; emission remains on source clock and pause freezes both', () {
    var wall = 0;
    final controller = configured(
      clock: () => wall,
      settings: const DanmakuSettings(followVideoRate: false, massive: true),
    );
    addTearDown(controller.dispose);
    controller.load(const [
      DanmakuComment(time: 1, text: 'one'),
      DanmakuComment(time: 2, text: 'two'),
      DanmakuComment(time: 3, text: 'three'),
    ]);
    controller.update(Duration.zero, playing: true, rate: 2);
    wall = 500;
    controller.tick();
    expect(controller.nowMs, 1000);
    expect(controller.animationNowMs, 500);
    expect(controller.active.single.text, 'one');
    controller.applySettings(
      controller.settings.copyWith(followVideoRate: true),
    );
    wall = 1000;
    controller.tick();
    expect(controller.nowMs, 2000);
    expect(controller.animationNowMs, 1500);
    expect(controller.active.map((item) => item.text), ['one', 'two']);
    controller.update(const Duration(seconds: 2), playing: false, rate: 2);
    wall = 12000;
    controller.tick();
    expect(controller.nowMs, 2000);
    expect(controller.animationNowMs, 1500);
    expect(controller.active, hasLength(2));
    controller.seek(Duration.zero);
    controller.update(Duration.zero, playing: true, rate: 1);
    wall = 13000;
    controller.tick();
    expect(controller.active.single.text, 'one');
  });

  test('type filters, local conversion and enabled state affect actual consumer entries', () {
    final converter = ZhConverter.fromMaps(s2t: {'后': '後'}, t2s: {'後': '后'});
    final controller = configured(
      converter: converter,
      settings: const DanmakuSettings(
        massive: true,
        conversion: ZhConversionMode.t2s,
        showTop: false,
        blockedWords: ['剧透'],
        blockedUsers: ['u'],
      ),
    );
    addTearDown(controller.dispose);
    controller.load(const [
      DanmakuComment(time: 1, text: '後来'),
      DanmakuComment(time: 1, text: 'top', mode: 5),
      DanmakuComment(time: 1, text: 'bottom', mode: 4),
      DanmakuComment(time: 1, text: '剧透'),
      DanmakuComment(time: 1, text: 'user', user: 'u'),
    ]);
    controller.update(const Duration(seconds: 1), playing: false);
    expect(controller.active.map((item) => item.text), ['后来', 'bottom']);
    controller.applySettings(controller.settings.copyWith(showBottom: false));
    expect(controller.active.single.text, '后来');
    controller.applySettings(controller.settings.copyWith(enabled: false));
    expect(controller.active, isEmpty);
  });

  test('zero region hides all; region and line height bound real lanes', () {
    final controller = configured(
      settings: const DanmakuSettings(area: 0, fontSize: 20, lineHeight: 2),
    );
    addTearDown(controller.dispose);
    controller.load(const [DanmakuComment(time: 1, text: 'hidden')]);
    controller.update(const Duration(seconds: 1), playing: false);
    expect(controller.laneCount, 0);
    expect(controller.active, isEmpty);
    controller.applySettings(controller.settings.copyWith(area: 0.5));
    expect(controller.areaHeight, 120);
    expect(controller.laneCount, 3);
    controller.applySettings(controller.settings.copyWith(lineHeight: 3));
    expect(controller.laneCount, 2);
    controller.applySettings(controller.settings.copyWith(lineHeight: 0));
    expect(controller.laneHeight, greaterThanOrEqualTo(20));
  });

  test('collision lanes reject overlap including fixed-vs-scroll; massive mode is bounded', () {
    final controller = configured(
      height: 26,
      settings: const DanmakuSettings(fontSize: 16, lineHeight: 1.6),
    );
    addTearDown(controller.dispose);
    final comments = [
      for (var i = 0; i < 400; i++)
        DanmakuComment(time: 1, text: '$i', mode: i == 0 ? 5 : 1),
    ];
    controller.load(comments);
    controller.update(const Duration(seconds: 1), playing: false);
    expect(controller.laneCount, 1);
    expect(controller.active, hasLength(1));
    controller.applySettings(
      controller.settings.copyWith(massive: true, maxActive: 20),
    );
    controller.seek(Duration.zero);
    controller.update(const Duration(seconds: 1), playing: false);
    expect(controller.active, hasLength(20));
    expect(
      controller.layoutCacheCount,
      lessThanOrEqualTo(DanmakuController.maxLayoutCache),
    );
  });

  test('duplicate window uses source seconds, clears on seek and counts merged entries', () {
    final controller = configured(
      settings: const DanmakuSettings(
        massive: true,
        mergeDuplicates: true,
        durationSeconds: 16,
      ),
    );
    addTearDown(controller.dispose);
    controller.load(const [
      DanmakuComment(time: 1, text: 'same'),
      DanmakuComment(time: 5.9, text: 'same'),
      DanmakuComment(time: 6.1, text: 'same'),
      DanmakuComment(time: 6.1, text: 'same', mode: 5),
    ]);
    controller.update(const Duration(seconds: 1), playing: false);
    controller.update(const Duration(seconds: 2), playing: false);
    controller.update(const Duration(seconds: 3), playing: false);
    controller.update(const Duration(seconds: 4), playing: false);
    controller.update(const Duration(seconds: 5), playing: false);
    controller.update(const Duration(milliseconds: 5900), playing: false);
    expect(controller.active, hasLength(1));
    expect(controller.active.single.duplicateCount, 2);
    controller.update(const Duration(milliseconds: 6100), playing: false);
    expect(controller.active, hasLength(3));
    controller.seek(Duration.zero);
    controller.update(const Duration(seconds: 1), playing: false);
    expect(controller.active.single.duplicateCount, 1);
  });

  test(
    'ticker removes expired active entries without new player position updates',
    () {
      var wall = 0;
      final controller = configured(
        clock: () => wall,
        settings: const DanmakuSettings(durationSeconds: 2),
      );
      addTearDown(controller.dispose);
      controller.load(const [DanmakuComment(time: 1, text: 'one')]);
      controller.update(const Duration(seconds: 1), playing: true);
      expect(controller.active, hasLength(1));
      final cacheSize = controller.layoutCacheCount;
      wall = 1000;
      controller.tick();
      expect(controller.layoutCacheCount, cacheSize);
      wall = 2001;
      controller.tick();
      expect(controller.active, isEmpty);
    },
  );

  test('layout painters cache repeated content and remain bounded across a long episode', () {
    var wall = 0;
    final controller = configured(
      clock: () => wall,
      settings: const DanmakuSettings(massive: true, durationSeconds: 2),
    );
    addTearDown(controller.dispose);
    controller.load([
      for (var index = 1; index <= 800; index++)
        DanmakuComment(time: index.toDouble(), text: '$index'),
    ]);
    controller.update(Duration.zero, playing: true);
    for (var second = 1; second <= 800; second++) {
      wall = second * 1000;
      controller.tick();
    }
    expect(controller.active.length, lessThanOrEqualTo(3));
    expect(
      controller.layoutCacheCount,
      lessThanOrEqualTo(DanmakuController.maxLayoutCache),
    );
  });

  test('a late load and large discontinuity skip history and rewind clears occupied lanes', () {
    final controller = configured(
      settings: const DanmakuSettings(massive: true),
    );
    addTearDown(controller.dispose);
    controller.update(const Duration(seconds: 100), playing: false);
    controller.load([
      for (var second = 0; second <= 110; second++)
        DanmakuComment(time: second.toDouble(), text: '$second'),
    ]);
    controller.update(const Duration(seconds: 101), playing: false);
    expect(controller.active.single.text, '101');
    controller.update(const Duration(seconds: 110), playing: false);
    expect(controller.active.single.text, '110');
    controller.seek(Duration.zero);
    controller.update(const Duration(seconds: 1), playing: false);
    expect(controller.active.single.text, '1');
  });

  test(
    'late converter completion uses the current episode after seek and dispose',
    () async {
      final pending = Completer<ZhConverter>();
      final controller =
          DanmakuController(
              settings: const DanmakuSettings(conversion: ZhConversionMode.t2s),
              converterLoader: () => pending.future,
            )
            ..height = 240
            ..configure(
              width: 400,
              laneHeight: 24,
              style: const TextStyle(fontSize: 16),
            );
      controller.load(const [DanmakuComment(time: 1, text: '舊話')]);
      controller.update(const Duration(seconds: 1), playing: false);
      controller.seek(Duration.zero);
      controller.load(const [DanmakuComment(time: 2, text: '後来')]);
      controller.update(const Duration(seconds: 2), playing: false);
      pending.complete(ZhConverter.fromMaps(s2t: {}, t2s: {'後': '后'}));
      await Future<void>.delayed(Duration.zero);
      expect(controller.active.single.text, '后来');
      expect(controller.active.single.comment.time, 2);
      controller.dispose();

      final disposedPending = Completer<ZhConverter>();
      final disposed = DanmakuController(
        settings: const DanmakuSettings(conversion: ZhConversionMode.t2s),
        converterLoader: () => disposedPending.future,
      );
      disposed.load(const []);
      disposed.dispose();
      disposedPending.complete(ZhConverter.fromMaps(s2t: {}, t2s: {}));
      await Future<void>.delayed(Duration.zero);
    },
  );

  testWidgets(
    'shared panel publishes immediately and settings persist in edit order',
    (tester) async {
      final preferences = memoryPreferences();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: DanmakuSettingsPanel(inPlayer: true)),
          ),
        ),
      );
      expect(find.text('弹幕设置 · 即时生效'), findsOneWidget);
      await tester.tap(find.text('显示弹幕'));
      await tester.pump();
      expect(container.read(danmakuSettingsProvider).enabled, isFalse);
      final slider = tester.widget<Slider>(find.byKey(const ValueKey('显示区域')));
      slider.onChanged!(0.5);
      expect(container.read(danmakuSettingsProvider).area, 0.5);
      final notifier = container.read(danmakuSettingsProvider.notifier);
      await notifier.update(
        container
            .read(danmakuSettingsProvider)
            .copyWith(shieldRules: const [DanmakuShieldRule(text: '剧透')]),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('恢复默认显示设置'),
        450,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('恢复默认显示设置'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '恢复默认'));
      await tester.pump();
      expect(container.read(danmakuSettingsProvider).enabled, isTrue);
      expect(
        container.read(danmakuSettingsProvider).shieldRules.single.text,
        '剧透',
      );
      await notifier.update(
        container.read(danmakuSettingsProvider).copyWith(area: 0.25),
      );
      expect(DanmakuSettings.load(preferences).area, 0.25);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
