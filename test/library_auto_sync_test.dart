import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/anime/data/anime_follow_sync.dart';
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
              events.add('dav');
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
              events.add('bangumi');
              if (bangumiError != null) throw bangumiError!;
            },
            cancel: () {
              cancellations++;
            },
            syncBangumiPriority: (priority) async {
              priorities.add(priority);
              events.add('bangumi');
              bangumiCalls++;
              if (bangumiError != null) throw bangumiError!;
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
  final events = <String>[];
  final priorities = <AnimeSyncPriority>[];
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
  testWidgets('cancel stops follows queued behind an automatic flight', (
    tester,
  ) async {
    final h = _Harness();
    final held = h.nextDav = Completer<String>();
    h.controller;
    await tester.pump();
    expect(h.events, ['dav']);
    final queued = h.controller.syncFollows(
      webDav: true,
      bangumi: true,
      priority: AnimeSyncPriority.local,
    );
    h.controller.cancelSync();
    held.complete('late');
    await queued;
    await tester.pump();
    expect(h.events, ['dav']);
    expect(h.state.syncing, isFalse);
    expect(h.state.lastSuccess, isNull);
    h.dispose();
  });

  testWidgets(
    'cancel keeps automatic edit listeners without an immediate new pass',
    (tester) async {
      final h = _Harness();
      final held = h.nextDav = Completer<String>();
      h.controller;
      await tester.pump();
      h.controller.cancelSync();
      held.complete('late');
      await tester.pump();
      await tester.pump(LibraryAutoSyncController.debounce);
      expect(h.dav, 1);
      h.edit();
      await tester.pump(LibraryAutoSyncController.debounce);
      expect(h.dav, 2);
      expect(h.state.lastSuccess, isNotNull);
      h.dispose();
    },
  );

  testWidgets(
    'cancel restores foreground remote polling without replaying immediately',
    (tester) async {
      final h = _Harness();
      final held = h.nextDav = Completer<String>();
      h.controller;
      await tester.pump();
      h.controller.cancelSync();
      held.complete('late');
      await tester.pump();
      expect(h.dav, 1);
      await tester.pump(LibraryAutoSyncController.pollInterval);
      expect(h.dav, 2);
      h.dispose();
    },
  );

  for (final type in [SourceErrorType.auth, SourceErrorType.network]) {
    testWidgets('DAV $type failure invalidates an established connection', (
      tester,
    ) async {
      final h = _Harness(enabled: false);
      h.controller;
      await tester.pump();
      await h.controller.syncNow();
      expect(h.state.connected, isTrue);
      h.syncError = SourceException(
        sourceId: 'webdav',
        type: type,
        message: 'fixture',
      );
      await h.controller.syncNow();
      expect(h.state.connected, isFalse);
      expect(h.state.error, isNotNull);
      h.syncError = null;
      await h.controller.syncNow();
      expect(h.probes, 2);
      expect(h.state.connected, isTrue);
      h.dispose();
    });
  }

  testWidgets('authentication failure replaces a prior conflict and blocks until recovery', (
    tester,
  ) async {
    final h = _Harness();
    h.controller;
    await tester.pump();
    expect(h.state.connected, isTrue);
    h.syncError = StateError('local edit during merge');
    await h.controller.syncNow();
    final conflictError = h.state.error;
    expect(conflictError, contains('合并期间'));
    expect(h.state.connected, isTrue);
    h.syncError = const SourceException(
      sourceId: 'webdav',
      type: SourceErrorType.auth,
      message: 'revoked fixture credentials',
    );
    await h.controller.syncNow();
    expect(h.state.connected, isFalse);
    expect(h.state.error, contains('认证失败或权限不足'));
    expect(h.state.error, isNot(conflictError));
    expect(h.state.stages[AnimeFollowSyncStage.webDav]!.message, h.state.error);
    final callsAfterAuthFailure = h.dav;
    h.edit();
    await tester.pump(const Duration(minutes: 10));
    expect(h.dav, callsAfterAuthFailure,
        reason: 'authentication failure must stop conflict retries and auto polling');
    expect(h.probes, 1);
    h.syncError = null;
    await h.controller.syncNow();
    expect(h.probes, 2);
    expect(h.dav, callsAfterAuthFailure + 1);
    expect(h.state.connected, isTrue);
    expect(h.state.error, isNull);
    expect(h.state.stages[AnimeFollowSyncStage.webDav]!.phase,
        AnimeFollowSyncPhase.succeeded);
    h.dispose();
  });

  testWidgets('DAV merge conflicts retain authenticated connection status', (
    tester,
  ) async {
    final h = _Harness(enabled: false);
    h.controller;
    await tester.pump();
    await h.controller.syncNow();
    h.syncError = StateError('local edit during merge');
    await h.controller.syncNow();
    expect(h.state.connected, isTrue);
    expect(h.state.error, isNotNull);
    expect(h.probes, 1);
    h.dispose();
  });

  testWidgets(
    'follows stages order DAV, Bangumi, upload and pass explicit priority',
    (tester) async {
      final h = _Harness(enabled: false);
      h.controller;
      await tester.pump();
      await h.controller.syncFollows(
        webDav: true,
        bangumi: true,
        priority: AnimeSyncPriority.local,
      );
      expect(h.events, ['dav', 'bangumi', 'dav']);
      expect(h.priorities, [AnimeSyncPriority.local]);
      expect(
        h.state.stages.values.map((step) => step.phase),
        everyElement(AnimeFollowSyncPhase.succeeded),
      );
      h.dispose();
    },
  );

  testWidgets(
    'DAV failure does not block optional Bangumi; upload remains skipped',
    (tester) async {
      final h = _Harness(enabled: false)
        ..syncError = const FormatException('bad fixture document');
      h.controller;
      await tester.pump();
      await h.controller.syncFollows(
        webDav: true,
        bangumi: true,
        priority: AnimeSyncPriority.bangumi,
      );
      expect(h.events, ['dav', 'bangumi']);
      expect(
        h.state.stages[AnimeFollowSyncStage.webDav]!.phase,
        AnimeFollowSyncPhase.failed,
      );
      expect(
        h.state.stages[AnimeFollowSyncStage.bangumi]!.phase,
        AnimeFollowSyncPhase.succeeded,
      );
      expect(
        h.state.stages[AnimeFollowSyncStage.upload]!.phase,
        AnimeFollowSyncPhase.skipped,
      );
      expect(h.state.error, isNotNull);
      expect(h.state.bangumiLastSuccess, isNotNull);
      h.dispose();
    },
  );

  testWidgets(
    'Bangumi failure preserves DAV result and reports independent stage error',
    (tester) async {
      final h = _Harness(enabled: false)
        ..bangumiError = const FormatException('bad fixture account');
      h.controller;
      await tester.pump();
      await h.controller.syncFollows(
        webDav: true,
        bangumi: true,
        priority: AnimeSyncPriority.newest,
      );
      expect(h.events, ['dav', 'bangumi']);
      expect(h.state.lastSuccess, isNotNull);
      expect(h.state.error, isNull);
      expect(h.state.bangumiError, isNotNull);
      expect(
        h.state.stages[AnimeFollowSyncStage.upload]!.phase,
        AnimeFollowSyncPhase.skipped,
      );
      h.dispose();
    },
  );

  testWidgets(
    'follows Bangumi-only works without DAV; generic manual sync stays DAV-only',
    (tester) async {
      final h = _Harness(configured: false, enabled: false);
      h.controller;
      await tester.pump();
      await h.controller.syncFollows(
        webDav: false,
        bangumi: true,
        priority: AnimeSyncPriority.bangumi,
      );
      expect(h.events, ['bangumi']);
      expect(
        h.state.stages[AnimeFollowSyncStage.webDav]!.phase,
        AnimeFollowSyncPhase.skipped,
      );
      await h.controller.syncNow();
      expect(h.events, ['bangumi']);
      h.dispose();
    },
  );

  testWidgets(
    'cancel discards late stage results and skips all later remote writes',
    (tester) async {
      final h = _Harness(enabled: false);
      h.controller;
      await tester.pump();
      final held = h.nextDav = Completer<String>();
      final operation = h.controller.syncFollows(
        webDav: true,
        bangumi: true,
        priority: AnimeSyncPriority.local,
      );
      await tester.pump();
      expect(h.events, ['dav']);
      h.controller.cancelSync();
      held.complete('late');
      await operation;
      expect(h.events, ['dav']);
      expect(h.state.syncing, isFalse);
      expect(h.state.lastSuccess, isNull);
      expect(
        h.state.stages.values.map((step) => step.phase),
        everyElement(AnimeFollowSyncPhase.cancelled),
      );
      h.dispose();
    },
  );

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
