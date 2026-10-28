import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/library_auto_sync.dart';
import 'package:triomi/features/profile/data/sync_providers.dart';

import 'fixtures/fake_preferences.dart';

const _config = WebDavConfig(
  baseUrl: 'https://dav.example.test/',
  username: 'fixture',
  password: 'fixture-only',
);

class _Harness {
  _Harness({
    bool configured = true,
    bool enabled = true,
    bool bangumi = false,
  }) {
    preferences = memoryPreferences();
    preferences.set(LibraryAutoSyncController.enabledKey, enabled);
    preferences.set(LibraryAutoSyncController.bangumiEnabledKey, bangumi);
    secure = MemorySecureStore();
    secure.set('tracking.bangumi.token', 'fixture-only');
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(secure),
        libraryAutoSyncRuntimeProvider.overrideWith(
          (ref) => LibraryAutoSyncRuntime(
            changes: changes.stream,
            revision: () async => '$revision',
            check: (_) async {
              probes++;
              if (probeError != null) throw probeError!;
            },
            syncDav: () async {
              dav++;
              final held = nextDav;
              nextDav = null;
              final captured = '$revision';
              if (held != null) return held.future;
              if (syncError != null) throw syncError!;
              if (ownChange) {
                revision++;
                changes.add(null);
              }
              final applied = ownChange ? '$revision' : captured;
              onDavApplied?.call();
              return applied;
            },
            syncBangumi: () async {
              bangumiCalls++;
              if (bangumiError != null) throw bangumiError!;
            },
            cancel: () {
              cancellations++;
            },
          ),
        ),
      ],
    );
    if (configured) {
      container.read(webDavConfigProvider.notifier).update(_config);
    }
  }
  late final ProviderContainer container;
  late final Preferences preferences;
  late final MemorySecureStore secure;
  final changes = StreamController<void>.broadcast(sync: true);
  int revision = 0, dav = 0, probes = 0, bangumiCalls = 0, cancellations = 0;
  Object? probeError, syncError, bangumiError;
  Completer<String>? nextDav;
  bool ownChange = false;
  void Function()? onDavApplied;
  LibraryAutoSyncController get controller =>
      container.read(libraryAutoSyncProvider.notifier);
  LibraryAutoSyncState get state => container.read(libraryAutoSyncProvider);
  void edit() {
    revision++;
    changes.add(null);
  }

  void dispose() {
    container.dispose();
    changes.close();
  }
}

void main() {
  testWidgets('configured startup probes DAV and shares manual collision', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pump();
    final held = h.nextDav = Completer<String>();
    h.controller;
    await tester.pump();
    expect(h.probes, 1);
    expect(h.dav, 1);
    final a = h.controller.syncNow();
    final b = h.controller.syncNow();
    expect(identical(a, b), isTrue);
    expect(h.dav, 1);
    held.complete('0');
    await tester.pump();
    expect(h.state.lastSuccess, isNotNull);
    h.dispose();
  });

  testWidgets(
    'resume and foreground poll see remote edits, pause stops polling',
    (tester) async {
      final h = _Harness();
      await tester.pump();
      h.controller;
      await tester.pump();
      expect(h.dav, 1);
      await tester.pump(LibraryAutoSyncController.pollInterval);
      expect(h.dav, 2);
      h.controller.onPaused();
      await tester.pump(const Duration(minutes: 9));
      expect(h.dav, 2);
      h.controller.onResumed();
      await tester.pump();
      expect(h.dav, 3);
      h.dispose();
    },
  );

  testWidgets(
    'five second playback updates flush by max wait without rate storm',
    (tester) async {
      final h = _Harness();
      await tester.pump();
      h.controller;
      await tester.pump();
      for (var index = 0; index < 6; index++) {
        h.edit();
        await tester.pump(const Duration(seconds: 5));
      }
      expect(h.dav, 2);
      expect(h.state.pending, isFalse);
      for (var index = 0; index < 6; index++) {
        h.edit();
        await tester.pump(const Duration(seconds: 5));
      }
      expect(h.dav, 3);
      h.dispose();
    },
  );

  testWidgets('own apply notifications do not upload forever', (tester) async {
    final h = _Harness()..ownChange = true;
    await tester.pump();
    h.controller;
    await tester.pump();
    await tester.pump(const Duration(seconds: 45));
    expect(h.dav, 1);
    expect(h.state.pending, isFalse);
    h.dispose();
  });

  testWidgets(
    'local change after applied snapshot receives another bounded pass',
    (tester) async {
      final h = _Harness();
      await tester.pump();
      h.onDavApplied = () {
        h.onDavApplied = null;
        h.edit();
      };
      h.controller;
      await tester.pump();
      expect(h.dav, 1);
      expect(h.state.pending, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(h.dav, 2);
      h.dispose();
    },
  );

  testWidgets(
    'endpoint switch discards late old-account success and cancels old owner',
    (tester) async {
      final h = _Harness();
      await tester.pump();
      final stale = h.nextDav = Completer<String>();
      h.controller;
      await tester.pump();
      await h.container
          .read(webDavConfigProvider.notifier)
          .update(
            const WebDavConfig(
              baseUrl: 'https://another.example.test/',
              username: 'second-fixture',
              password: 'fixture-only',
            ),
          );
      h.syncError = const SourceException(
        sourceId: 'webdav',
        type: SourceErrorType.auth,
        message: 'fixture',
      );
      await tester.pump();
      stale.complete('stale');
      await tester.pump();
      expect(h.cancellations, greaterThanOrEqualTo(1));
      expect(h.state.lastSuccess, isNull);
      expect(h.state.error, isNotNull);
      h.dispose();
    },
  );

  testWidgets(
    'transient failure backs off then recovery preserves local pending edits',
    (tester) async {
      final h = _Harness()
        ..syncError = const SourceException(
          sourceId: 'webdav',
          type: SourceErrorType.network,
          message: 'fixture',
        );
      await tester.pump();
      h.controller;
      await tester.pump();
      expect(h.dav, 1);
      expect(h.state.error, isNotNull);
      for (var index = 0; index < 5; index++) {
        h.edit();
        await tester.pump(const Duration(seconds: 5));
      }
      expect(h.dav, 1);
      h.syncError = null;
      await tester.pump(const Duration(seconds: 5));
      expect(h.dav, 2);
      expect(h.state.lastSuccess, isNotNull);
      expect(h.state.error, isNull);
      h.dispose();
    },
  );

  testWidgets('opt out persists, cancels polling, manual remains available', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pump();
    h.controller;
    await tester.pump();
    await h.controller.setEnabled(false);
    h.edit();
    await tester.pump(const Duration(minutes: 10));
    expect(h.dav, 1);
    expect(
      h.preferences.get<bool>(LibraryAutoSyncController.enabledKey),
      isFalse,
    );
    await h.controller.syncNow();
    expect(h.dav, 2);
    h.dispose();
  });

  testWidgets('unconfigured and opted-out installs never create runtime', (
    tester,
  ) async {
    final h = _Harness(configured: false);
    h.controller;
    await tester.pump(const Duration(minutes: 10));
    expect(h.probes, 0);
    expect(h.dav, 0);
    h.dispose();
  });

  testWidgets(
    'Bangumi has separate opt-in, partial failure retains DAV success',
    (tester) async {
      final h = _Harness();
      await tester.pump();
      h.controller;
      await tester.pump();
      expect(h.bangumiCalls, 0);
      h.bangumiError = const SourceException(
        sourceId: 'bangumi',
        type: SourceErrorType.auth,
        message: 'fixture',
      );
      await h.controller.setBangumiEnabled(true);
      await tester.pump();
      expect(h.bangumiCalls, 1);
      expect(h.state.lastSuccess, isNotNull);
      expect(h.state.error, isNull);
      expect(h.state.bangumiError, isNotNull);
      h.dispose();
    },
  );

  testWidgets(
    'Bangumi-only opt in works without DAV, even when DAV automatic is off',
    (tester) async {
      final h = _Harness(configured: false, enabled: false, bangumi: true);
      h.controller;
      await tester.pump();
      expect(h.probes, 0);
      expect(h.dav, 0);
      expect(h.bangumiCalls, 1);
      expect(h.state.bangumiLastSuccess, isNotNull);
      h.dispose();
    },
  );

  testWidgets('disposal cancels in-flight owner and discards late response', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pump();
    final held = h.nextDav = Completer<String>();
    h.controller;
    await tester.pump();
    expect(h.dav, 1);
    h.dispose();
    held.complete('late');
    await tester.pump(const Duration(minutes: 10));
    expect(h.cancellations, 1);
    expect(h.dav, 1);
  });

  testWidgets('authentication failure waits for a user probe or resume', (
    tester,
  ) async {
    final h = _Harness()
      ..probeError = const SourceException(
        sourceId: 'webdav',
        type: SourceErrorType.auth,
        message: 'fixture',
      );
    await tester.pump();
    h.controller;
    await tester.pump();
    expect(h.probes, 1);
    expect(h.state.connected, isFalse);
    h.edit();
    await tester.pump(const Duration(minutes: 12));
    expect(h.probes, 1);
    expect(h.dav, 0);
    h.probeError = null;
    h.controller.onResumed();
    await tester.pump();
    expect(h.probes, 2);
    expect(h.dav, 1);
    expect(h.state.connected, isTrue);
    h.dispose();
  });
}
