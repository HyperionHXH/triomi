import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/library/data/manga_update_background.dart';
import 'package:triomi/features/library/data/windows_content_updates.dart';
import 'package:triomi/features/schedule/data/background_update_check.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'reconciling either switch preserves the other in one shared native task',
    () async {
      final prefs = memoryPreferences();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      await prefs.set(backgroundCheckPreferenceKey, true);
      await prefs.set('manga.updates.background', true);
      expect(await reconcileWindowsContentUpdateSchedule(prefs), isTrue);
      await prefs.set(backgroundCheckPreferenceKey, false);
      expect(await reconcileWindowsContentUpdateSchedule(prefs), isTrue);
      expect(calls.map((c) => c.method).toSet(), {'scheduleMangaUpdates'});
      expect(calls.last.arguments, {
        'backgroundCheck': false,
        'mangaUpdates': true,
      });
      await prefs.set('manga.updates.background', false);
      expect(await reconcileWindowsContentUpdateSchedule(prefs), isTrue);
      expect(calls.last.arguments, {
        'backgroundCheck': false,
        'mangaUpdates': false,
      });
    },
  );

  test('native refusal and exceptions preserve choices and persist actionable errors', () async {
    final prefs = memoryPreferences();
    await prefs.set(backgroundCheckPreferenceKey, true);
    await prefs.set('manga.updates.background', true);
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await reconcileWindowsContentUpdateSchedule(prefs), isFalse);
    expect(prefs.get<bool>(backgroundCheckPreferenceKey), isTrue);
    expect(prefs.get<bool>('manga.updates.background'), isTrue);
    expect(
      prefs.get<String>(windowsContentScheduleErrorKey),
      contains('偏好已保留'),
    );
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'denied', message: 'secret-url-password');
    });
    expect(await reconcileWindowsContentUpdateSchedule(prefs), isFalse);
    expect(
      prefs.get<String>(windowsContentScheduleErrorKey),
      isNot(contains('secret')),
    );
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    expect(await reconcileWindowsContentUpdateSchedule(prefs), isTrue);
    expect(prefs.get<String>(windowsContentScheduleErrorKey), isNull);
  });

  test(
    'overlapping registration requests serialize and re-read latest switches',
    () async {
      final prefs = memoryPreferences();
      final entered = Completer<void>(), release = Completer<void>();
      final arguments = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        arguments.add(call.arguments);
        if (arguments.length == 1) {
          entered.complete();
          await release.future;
        }
        return true;
      });
      await prefs.set(backgroundCheckPreferenceKey, true);
      final first = reconcileWindowsContentUpdateSchedule(prefs);
      await entered.future;
      await prefs.set('manga.updates.background', true);
      final second = reconcileWindowsContentUpdateSchedule(prefs);
      release.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(arguments.last, {'backgroundCheck': true, 'mangaUpdates': true});
    },
  );

  test('startup resume and timer coalesce one production flight then respect twelve hours', () async {
    final prefs = memoryPreferences();
    await prefs.set(backgroundCheckPreferenceKey, true);
    await prefs.set('manga.updates.background', true);
    final entered = Completer<void>(), release = Completer<void>();
    var anime = 0, manga = 0;
    var now = DateTime(2026, 11, 8, 1);
    final coordinator = WindowsContentUpdateCoordinator(
      preferences: prefs,
      now: () => now,
      runAnime: (_) async {
        anime++;
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      },
      runManga: (_) async {
        manga++;
      },
    );
    final first = coordinator.run();
    await entered.future;
    final second = coordinator.run();
    expect(identical(first, second), isTrue);
    release.complete();
    await Future.wait([first, second]);
    expect((anime, manga), (1, 1));
    await coordinator.run();
    expect((anime, manga), (1, 1));
    now = now.add(windowsContentInterval);
    await coordinator.run();
    expect((anime, manga), (2, 2));
    await coordinator.dispose();
  });

  test('disabled work is skipped and cancelling an active run does not mark it complete', () async {
    final prefs = memoryPreferences();
    var anime = 0, manga = 0;
    final entered = Completer<void>(), release = Completer<void>();
    WindowsContentUpdateCancellation? cancellation;
    final coordinator = WindowsContentUpdateCoordinator(
      preferences: prefs,
      runAnime: (_) async {
        anime++;
      },
      runManga: (token) async {
        manga++;
        cancellation = token;
        entered.complete();
        await release.future;
      },
    );
    await coordinator.run();
    expect((anime, manga), (0, 0));
    await prefs.set('manga.updates.background', true);
    final active = coordinator.run();
    await entered.future;
    await prefs.set('manga.updates.background', false);
    coordinator.cancel();
    expect(cancellation!.cancelled, isTrue);
    release.complete();
    await active;
    expect(prefs.get<String>('content.updates.mangaCompleted'), isNull);
    expect((anime, manga), (0, 1));
    await coordinator.dispose();
    await coordinator.run(force: true);
    expect(manga, 1);
  });

  test('one failing source class does not suppress the other and failure remains due', () async {
    final prefs = memoryPreferences();
    await prefs.set(backgroundCheckPreferenceKey, true);
    await prefs.set('manga.updates.background', true);
    var anime = 0, manga = 0;
    final coordinator = WindowsContentUpdateCoordinator(
      preferences: prefs,
      runAnime: (_) async {
        anime++;
        throw StateError('https://user:credential@example.invalid');
      },
      runManga: (_) async {
        manga++;
      },
    );
    await coordinator.run();
    expect((anime, manga), (1, 1));
    expect(prefs.get<String>('content.updates.animeCompleted'), isNull);
    expect(
      prefs.get<String>('content.updates.animeCompleted.error'),
      isNot(contains('credential')),
    );
    expect(prefs.get<String>('content.updates.mangaCompleted'), isNotNull);
    await coordinator.run();
    expect((anime, manga), (2, 1));
    await coordinator.dispose();
  });
  test('desktop notification waits for native presentation completion, not queue acceptance', () async {
    const notifications = MethodChannel('triomi/content-notifications');
    final entered = Completer<void>(), presented = Completer<bool>();
    messenger.setMockMethodCallHandler(notifications, (call) async {
      expect(call.method, 'notify');
      entered.complete();
      return presented.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(notifications, null));
    var completed = false;
    final notification = notifyWindowsContentUpdate(title: 'manga', body: 'new chapters')
        .then((_) => completed = true);
    await entered.future;
    expect(completed, isFalse);
    presented.complete(true);
    await notification;
    expect(completed, isTrue);
  });

  test('unshown desktop notification rejection cannot be acknowledged as delivery', () async {
    const notifications = MethodChannel('triomi/content-notifications');
    messenger.setMockMethodCallHandler(notifications, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(notifications, null));
    await expectLater(notifyWindowsContentUpdate(title: 'manga', body: 'new'),
        throwsA(isA<StateError>()));
  });

  test('hidden transfers activate execution lease and release it on interruption without completion stamp', () async {
    final prefs = memoryPreferences();
    await prefs.set('manga.updates.background', true);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final coordinator = WindowsContentUpdateCoordinator(
      preferences: prefs,
      runAnime: (_) async {},
      runManga: (_) => withMangaAutoDownloadLease(() async {
        expect(calls.map((c) => c.method), ['beginDownloadQueue', 'setDownloadQueueActive']);
        expect(calls.last.arguments, {'active': true});
        throw const MangaUpdateIncomplete();
      }),
    );
    await coordinator.run();
    expect(calls.map((c) => c.method), [
      'beginDownloadQueue', 'setDownloadQueueActive', 'setDownloadQueueActive', 'endDownloadQueue',
    ]);
    expect(calls[2].arguments, {'active': false});
    expect(prefs.get<String>('content.updates.mangaCompleted'), isNull);
    expect(prefs.get<String>('content.updates.mangaCompleted.error'), isNotNull);
    await coordinator.dispose();
  });

  test('refused execution activation never starts transfers and still ends queue lease', () async {
    final calls = <MethodCall>[];
    var transferred = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method != 'setDownloadQueueActive' ||
          (call.arguments as Map)['active'] == false;
    });
    await expectLater(withMangaAutoDownloadLease(() async { transferred = true; }),
        throwsA(isA<MangaUpdateIncomplete>()));
    expect(transferred, isFalse);
    expect(calls.map((c) => c.method), [
      'beginDownloadQueue', 'setDownloadQueueActive', 'setDownloadQueueActive', 'endDownloadQueue',
    ]);
  });
}
