import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/settings/privacy_lock_controller.dart';
import 'package:triomi/features/settings/privacy_lock_gate.dart';
import 'package:triomi/features/settings/privacy_lock_settings_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> fastHash(String pin, Uint8List salt, int iterations) async =>
      derivePrivacyPin(pin, salt, 2);

  PrivacyLockController controller(Preferences preferences, SecureStore store,
          {DateTime Function()? clock, PrivacyPinDeriver? derive}) =>
      PrivacyLockController.forTesting(
        preferences: preferences,
        secureStore: () => store,
        clock: clock,
        derive: derive ?? fastHash,
      );

  test('PBKDF2-HMAC-SHA256 matches the published two-iteration vector', () {
    final result = derivePrivacyPin('password', Uint8List.fromList(utf8.encode('salt')), 2);
    final hex = result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    expect(hex, 'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
  });
  test('confirmed PIN protects cold reopen and correct PIN unlocks', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    final lock = controller(preferences, secure);
    expect(lock.status, PrivacyLockStatus.disabled);
    expect(await lock.enable('123456', '654321'), PrivacyLockResult.mismatch);
    expect(lock.enabled, isFalse);
    expect(await lock.enable('123456', '123456'), PrivacyLockResult.success);
    expect(lock.status, PrivacyLockStatus.unlocked);
    expect(secure.get(PrivacyLockController.recordKey), isNot(contains('123456')));
    expect(preferences.exportAll().values, isNot(contains('123456')));

    final reopened = controller(preferences, secure);
    expect(reopened.status, PrivacyLockStatus.locked);
    expect(await reopened.unlock('654321'), PrivacyLockResult.wrongPin);
    expect(reopened.blocksAccess, isTrue);
    expect(await reopened.unlock('123456'), PrivacyLockResult.success);
    expect(reopened.blocksAccess, isFalse);
  });

  test('five wrong guesses are durable across controller reopen', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    var now = DateTime.utc(2026, 10, 15);
    final lock = controller(preferences, secure, clock: () => now);
    await lock.enable('123456', '123456');
    lock.lock();
    for (var i = 0; i < 5; i++) {
      expect(await lock.unlock('999999'), PrivacyLockResult.wrongPin);
    }
    expect(lock.retryAfter, const Duration(seconds: 30));
    final reopened = controller(preferences, secure, clock: () => now);
    expect(await reopened.unlock('123456'), PrivacyLockResult.rateLimited);
    expect(reopened.blocksAccess, isTrue);
    now = now.add(const Duration(seconds: 31));
    expect(await reopened.unlock('123456'), PrivacyLockResult.success);
    expect(reopened.retryAfter, Duration.zero);
  });

  test('PIN change and disable require the current PIN', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    final lock = controller(preferences, secure);
    expect(await lock.enable('12345', '12345'), PrivacyLockResult.invalidPin);
    await lock.enable('123456', '123456');
    expect(await lock.disable(''), PrivacyLockResult.wrongPin);
    expect(lock.enabled, isTrue);
    expect(await lock.changePin('999999', '654321', '654321'), PrivacyLockResult.wrongPin);
    expect(await lock.changePin('123456', '654321', '654321'), PrivacyLockResult.success);
    lock.lock();
    expect(await lock.unlock('123456'), PrivacyLockResult.wrongPin);
    expect(await lock.unlock('654321'), PrivacyLockResult.success);
    expect(await lock.disable('654321'), PrivacyLockResult.success);
    expect(preferences.get<bool>(PrivacyLockController.enabledKey), isFalse);
    expect(secure.get(PrivacyLockController.recordKey), isNull);
    expect(controller(preferences, secure).status, PrivacyLockStatus.disabled);
  });

  test('unavailable, missing and corrupt enabled storage fails closed', () async {
    final preferences = memoryPreferences();
    await preferences.set(PrivacyLockController.enabledKey, true);
    final secure = MemorySecureStore();
    final missing = controller(preferences, secure);
    expect(missing.status, PrivacyLockStatus.unavailable);
    expect(await missing.unlock('123456'), PrivacyLockResult.unavailable);
    await secure.set(PrivacyLockController.recordKey, '{broken');
    final corrupt = controller(preferences, secure);
    expect(corrupt.blocksAccess, isTrue);
    expect(await corrupt.disable('123456'), PrivacyLockResult.unavailable);
    final throwsOnRead = PrivacyLockController.forTesting(
      preferences: preferences,
      secureStore: () => throw StateError('storage cannot open'),
    );
    expect(throwsOnRead.status, PrivacyLockStatus.unavailable);
    expect(await throwsOnRead.disable('123456'), PrivacyLockResult.unavailable);
  });

  test('disabled lock does not instantiate a secure store', () {
    final disabled = PrivacyLockController.forTesting(
      preferences: memoryPreferences(),
      secureStore: () => throw StateError('must not be read'),
    );
    expect(disabled.status, PrivacyLockStatus.disabled);
  });

  test('background and resume lock, including a late PIN verification', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    var delay = false;
    final pending = Completer<void>();
    final lock = controller(preferences, secure, derive: (pin, salt, iterations) async {
      if (delay) await pending.future;
      return fastHash(pin, salt, iterations);
    });
    await lock.enable('123456', '123456');
    lock.onLifecycleChanged(AppLifecycleState.inactive);
    expect(lock.blocksAccess, isTrue);
    lock.onLifecycleChanged(AppLifecycleState.resumed);
    expect(lock.blocksAccess, isTrue);
    delay = true;
    final unlocking = lock.unlock('123456');
    await Future<void>.delayed(Duration.zero);
    lock.onLifecycleChanged(AppLifecycleState.paused);
    lock.onLifecycleChanged(AppLifecycleState.resumed);
    pending.complete();
    expect(await unlocking, PrivacyLockResult.success);
    expect(lock.blocksAccess, isTrue);
  });

  for (final mutation in ['disable', 'change']) {
    test('$mutation cannot commit a PIN verification completed after background', () async {
      final preferences = memoryPreferences();
      final secure = MemorySecureStore();
      var delayed = false;
      final verifying = Completer<void>();
      final release = Completer<void>();
      final lock = controller(preferences, secure, derive: (pin, salt, iterations) async {
        if (delayed) {
          if (!verifying.isCompleted) verifying.complete();
          await release.future;
        }
        return fastHash(pin, salt, iterations);
      });
      await lock.enable('123456', '123456');
      delayed = true;
      final result = mutation == 'disable'
          ? lock.disable('123456')
          : lock.changePin('123456', '654321', '654321');
      await verifying.future;
      lock.onLifecycleChanged(AppLifecycleState.paused);
      lock.onLifecycleChanged(AppLifecycleState.resumed);
      release.complete();
      expect(await result, PrivacyLockResult.cancelled);
      expect(lock.blocksAccess, isTrue);
      expect(preferences.get<bool>(PrivacyLockController.enabledKey), isTrue);
      final reopened = controller(preferences, secure);
      expect(await reopened.unlock('123456'), PrivacyLockResult.success);
    });
  }

  test('interrupted durable disable marker keeps cold reopen locked', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    await controller(preferences, secure).enable('123456', '123456');
    await preferences.set(PrivacyLockController.disablePendingKey, true);
    await preferences.set(PrivacyLockController.enabledKey, false);
    final interrupted = controller(preferences, secure);
    expect(interrupted.blocksAccess, isTrue);
    expect(await interrupted.unlock('123456'), PrivacyLockResult.success);
    expect(await interrupted.disable('123456'), PrivacyLockResult.success);
    expect(controller(preferences, secure).status, PrivacyLockStatus.disabled);
  });

  test('secure write failure during setup cannot set enabled marker', () async {
    final preferences = memoryPreferences();
    final secure = _FailingSecureStore()..failWrites = true;
    final lock = controller(preferences, secure);
    expect(await lock.enable('123456', '123456'), PrivacyLockResult.unavailable);
    expect(preferences.get<bool>(PrivacyLockController.enabledKey), isNot(true));
    expect(lock.status, PrivacyLockStatus.disabled);
    secure.failWrites = false;
    expect(await lock.enable('123456', '123456'), PrivacyLockResult.success);
    secure.failWrites = true;
    lock.lock();
    expect(await lock.unlock('123456'), PrivacyLockResult.unavailable);
    expect(lock.blocksAccess, isTrue);
  });

  test('protected guesses survive a real preferences close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp('triomi-privacy-lock-');
    final secure = MemorySecureStore();
    final now = DateTime.utc(2026, 10, 15);
    final box = await Hive.openBox<dynamic>('privacy-lock-reopen', path: directory.path);
    final lock = controller(Preferences(box), secure, clock: () => now);
    await lock.enable('123456', '123456');
    for (var i = 0; i < 5; i++) {
      await lock.unlock('999999');
    }
    await box.close();
    final reopenedBox = await Hive.openBox<dynamic>('privacy-lock-reopen', path: directory.path);
    final reopenedSecure = MemorySecureStore();
    for (final key in secure.keys) {
      await reopenedSecure.set(key, secure.get(key)!);
    }
    final reopened = controller(Preferences(reopenedBox), reopenedSecure, clock: () => now);
    expect(reopened.status, PrivacyLockStatus.locked);
    expect(await reopened.unlock('123456'), PrivacyLockResult.rateLimited);
    await reopenedBox.close();
    await directory.delete(recursive: true);
  });

  testWidgets('cold gate and relock hide child interaction without disposing it', (tester) async {
    final semantics = tester.ensureSemantics();
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    final initial = controller(preferences, secure);
    await initial.enable('123456', '123456');
    final lock = controller(preferences, secure);
    var interactions = 0;
    var mounts = 0;
    var disposals = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [privacyLockProvider.overrideWithValue(lock)],
      child: MaterialApp(home: PrivacyLockGate(child: _MountedChild(
        onMounted: () => mounts++,
        onDisposed: () => disposals++,
        onPressed: () => interactions++,
      ))),
    ));
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('输入 PIN 解锁'), findsOneWidget);
    expect(mounts, 0);
    expect(find.text('Private content'), findsNothing);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.longPress(find.byType(TextField));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(Overlay.maybeOf(tester.element(find.byType(TextField))), isNotNull);
    await tester.tap(find.byType(TextField));
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(mounts, 1);
    await tester.tap(find.text('Private content'));
    expect(interactions, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('输入 PIN 解锁'), findsOneWidget);
    expect(find.text('Private content'), findsNothing);
    expect(find.text('应用已锁定'), findsOneWidget);
    expect(disposals, 0);
    expect(await PrivacyLockBackButtonDispatcher(lock).didPopRoute(), isTrue);
    expect(interactions, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposals, 1);
    semantics.dispose();
  });

  testWidgets('settings setup is usable with large text and confirmation', (tester) async {
    final preferences = memoryPreferences();
    final lock = controller(preferences, MemorySecureStore());
    await tester.pumpWidget(ProviderScope(
      overrides: [privacyLockProvider.overrideWithValue(lock)],
      child: MaterialApp(builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ), home: const PrivacyLockSettingsPage()),
    ));
    await tester.enterText(find.byType(TextField).at(0), '123456');
    await tester.enterText(find.byType(TextField).at(1), '654321');
    await tester.ensureVisible(find.text('确认并开启隐私锁'));
    await tester.tap(find.text('确认并开启隐私锁'));
    await tester.pumpAndSettle();
    expect(lock.enabled, isFalse);
    expect(find.text('两次输入的 PIN 不一致'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('portable export and malicious import cannot migrate or disable lock', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    final lock = controller(preferences, secure);
    await lock.enable('123456', '123456');
    final database = openTestDatabase();
    addTearDown(database.close);
    final service = BackupService(
      database: database,
      preferences: preferences,
      http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
    );
    final backup = await service.exportToBytes(includeCovers: false);
    final payload = BackupService.validatedPayload(backup.bytes);
    expect((payload['settingsValues'] as Map).containsKey(PrivacyLockController.enabledKey), isFalse);
    final incoming = {
      'version': backupFormatVersion,
      'exportedAt': '2026-10-15T00:00:00.000Z',
      'items': 0,
      'library': 0,
      'history': 0,
      'chapters': 0,
      'covers': 0,
      'settings': 1,
      'mediaItems': <Object?>[],
      'libraryEntries': <Object?>[],
      'histories': <Object?>[],
      'chapterRows': <Object?>[],
      'settingsValues': {PrivacyLockController.enabledKey: false},
    };
    final archive = Archive()..addFile(ArchiveFile.bytes(
      BackupService.dataFileName,
      Uint8List.fromList(utf8.encode(jsonEncode(incoming))),
    ));
    await service.importFromBytes(Uint8List.fromList(ZipEncoder().encode(archive)));
    expect(controller(preferences, secure).blocksAccess, isTrue);
    expect(preferences.get<bool>(PrivacyLockController.enabledKey), isTrue);
  });

  test('production secure store read failure remains closed and can retry', () async {
    final preferences = memoryPreferences();
    final seed = MemorySecureStore();
    await controller(preferences, seed).enable('123456', '123456');
    var fail = true;
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    const durable = MethodChannel('triomi/secure-store-durable');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(durable, (call) async {
      if (fail) throw PlatformException(code: 'read_unavailable');
      if (call.method == 'read') return seed.get(PrivacyLockController.recordKey);
      if (call.method == 'write') return call.arguments['value'];
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(durable, null));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readAll') {
        if (fail) throw PlatformException(code: 'read_unavailable');
        return {PrivacyLockController.recordKey: seed.get(PrivacyLockController.recordKey)!};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final store = FlutterSecureStore();
    await store.init();
    final lock = controller(preferences, store);
    expect(lock.status, PrivacyLockStatus.unavailable);
    expect(await lock.unlock('123456'), PrivacyLockResult.unavailable);
    fail = false;
    await lock.retryStorage();
    expect(lock.status, PrivacyLockStatus.locked);
    expect(await lock.unlock('123456'), PrivacyLockResult.success);
  });

  testWidgets('root gate covers cold deep links and consumes system Back', (tester) async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    await controller(preferences, secure).enable('123456', '123456');
    final lock = controller(preferences, secure);
    var mounts = 0;
    final router = GoRouter(initialLocation: '/private', routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('Home route'))),
      GoRoute(path: '/private', builder: (_, _) => _MountedChild(
        onMounted: () => mounts++, onDisposed: () {}, onPressed: () {},
      )),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        privacyLockProvider.overrideWithValue(lock),
        routerProvider.overrideWithValue(router),
      ],
      child: const TriomiApp(),
    ));
    await tester.pumpAndSettle();
    expect(mounts, 0);
    expect(find.text('Private content'), findsNothing);
    await tester.binding.handlePopRoute();
    expect(lock.blocksAccess, isTrue);
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.text('Home route'), findsNothing);
    expect(lock.blocksAccess, isTrue);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(find.text('Home route'), findsOneWidget);
    router.go('/private');
    await tester.pumpAndSettle();
    expect(mounts, 1);
    lock.lock();
    await tester.pumpAndSettle();
    expect(find.text('Private content'), findsNothing);
    await tester.binding.handlePopRoute();
    expect(lock.blocksAccess, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _FailingSecureStore extends MemorySecureStore {
  bool failWrites = false;

  @override
  Future<void> set(String key, String value) async {
    if (failWrites) throw PlatformException(code: 'write_failed');
    await super.set(key, value);
  }
}

class _MountedChild extends StatefulWidget {
  const _MountedChild({required this.onMounted, required this.onDisposed, required this.onPressed});
  final VoidCallback onMounted;
  final VoidCallback onDisposed;
  final VoidCallback onPressed;

  @override
  State<_MountedChild> createState() => _MountedChildState();
}

class _MountedChildState extends State<_MountedChild> {
  @override
  void initState() {
    super.initState();
    widget.onMounted();
  }

  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: FilledButton(onPressed: widget.onPressed, child: const Text('Private content'))),
  );
}
