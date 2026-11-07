import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/webdav_client.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import '../../anime/data/anime_collection_service.dart';
import '../../anime/data/anime_follow_sync.dart';
import '../../profile/data/sync_providers.dart';
import 'library_webdav_sync.dart';

enum AnimeFollowSyncStage { webDav, bangumi, upload }

enum AnimeFollowSyncPhase {
  waiting,
  running,
  succeeded,
  failed,
  skipped,
  cancelled,
}

class AnimeFollowSyncStep {
  const AnimeFollowSyncStep(this.phase, [this.message]);
  final AnimeFollowSyncPhase phase;
  final String? message;
}

/// Public status contains no endpoint, account name, token or password.
class LibraryAutoSyncState {
  const LibraryAutoSyncState({
    this.enabled = true,
    this.bangumiEnabled = false,
    this.configured = false,
    this.connected = false,
    this.checking = false,
    this.syncing = false,
    this.pending = false,
    this.checkedAt,
    this.lastSuccess,
    this.error,
    this.bangumiError,
    this.bangumiLastSuccess,
    this.stages = const {},
  });
  final bool enabled, bangumiEnabled, configured, connected;
  final bool checking, syncing, pending;
  final DateTime? checkedAt, lastSuccess, bangumiLastSuccess;
  final String? error, bangumiError;
  final Map<AnimeFollowSyncStage, AnimeFollowSyncStep> stages;

  LibraryAutoSyncState copyWith({
    bool? enabled,
    bool? bangumiEnabled,
    bool? configured,
    bool? connected,
    bool? checking,
    bool? syncing,
    bool? pending,
    DateTime? checkedAt,
    DateTime? lastSuccess,
    DateTime? bangumiLastSuccess,
    String? error,
    String? bangumiError,
    bool clearError = false,
    bool clearBangumiError = false,
    Map<AnimeFollowSyncStage, AnimeFollowSyncStep>? stages,
  }) => LibraryAutoSyncState(
    enabled: enabled ?? this.enabled,
    bangumiEnabled: bangumiEnabled ?? this.bangumiEnabled,
    configured: configured ?? this.configured,
    connected: connected ?? this.connected,
    checking: checking ?? this.checking,
    syncing: syncing ?? this.syncing,
    pending: pending ?? this.pending,
    checkedAt: checkedAt ?? this.checkedAt,
    lastSuccess: lastSuccess ?? this.lastSuccess,
    bangumiLastSuccess: bangumiLastSuccess ?? this.bangumiLastSuccess,
    error: clearError ? null : error ?? this.error,
    bangumiError: clearBangumiError ? null : bangumiError ?? this.bangumiError,
    stages: stages ?? this.stages,
  );
}

/// Injectable operation boundary. Scheduling tests use real timers in fake time;
/// production shares the existing canonical merge services and cancellation.
class LibraryAutoSyncRuntime {
  const LibraryAutoSyncRuntime({
    required this.changes,
    required this.revision,
    required this.check,
    required this.syncDav,
    required this.syncBangumi,
    required this.cancel,
    this.syncBangumiPriority,
  });
  final Stream<void> changes;
  final Future<String> Function() revision;
  final Future<void> Function(WebDavConfig) check;
  final Future<String> Function() syncDav;
  final Future<void> Function() syncBangumi;
  final Future<void> Function(AnimeSyncPriority)? syncBangumiPriority;
  final void Function() cancel;
}

final libraryAutoSyncRuntimeProvider = Provider<LibraryAutoSyncRuntime>((ref) {
  final db = ref.watch(databaseProvider);
  // Capture services lazily: an unconfigured installation must not open its DB
  // or sources merely because a status subtitle is visible.
  LibraryWebDavSync? dav;
  AnimeFollowSync? anime;
  final client = ref.read(webDavClientProvider);
  Future<String> revision() async {
    final values = <Object?>[];
    for (final query in [
      "SELECT source_id,remote_id,type,status,progress,added_at FROM library_entries WHERE type IN ('manga','anime') ORDER BY source_id,remote_id",
      "SELECT h.source_id,h.remote_id,h.chapter_source_id,h.chapter_remote_id,h.position,h.visited_at FROM histories h INNER JOIN media_items m ON m.source_id=h.source_id AND m.remote_id=h.remote_id WHERE h.incognito=0 AND m.type IN ('manga','anime') ORDER BY h.source_id,h.remote_id,h.chapter_source_id,h.chapter_remote_id",
      'SELECT source_id,remote_id,chapter_source_id,chapter_remote_id,history_reset_at FROM manga_chapter_states WHERE history_reset_at IS NOT NULL ORDER BY source_id,remote_id,chapter_source_id,chapter_remote_id',
      'SELECT account_key,source_id,remote_id,changed_at,deleted FROM anime_follow_sync_states ORDER BY account_key,source_id,remote_id',
      'SELECT * FROM anime_source_links ORDER BY subject_source_id,subject_remote_id,source_id',
      "SELECT source_id,remote_id,title,url,cover_url,author,description,tags_json,rating,status,detail_json FROM media_items WHERE type IN ('manga','anime') AND (EXISTS(SELECT 1 FROM library_entries l WHERE l.source_id=media_items.source_id AND l.remote_id=media_items.remote_id) OR EXISTS(SELECT 1 FROM histories h WHERE h.source_id=media_items.source_id AND h.remote_id=media_items.remote_id AND h.incognito=0)) ORDER BY source_id,remote_id",
    ]) {
      values.add([
        for (final row in await db.customSelect(query).get()) row.data,
      ]);
    }
    return sha256.convert(utf8.encode(jsonEncode(values))).toString();
  }

  return LibraryAutoSyncRuntime(
    changes: db
        .tableUpdates(
          TableUpdateQuery.onAllTables({
            db.libraryEntries,
            db.histories,
            db.animeFollowSyncStates,
            db.animeSourceLinks,
            db.mediaItems,
            db.mangaChapterStates,
          }),
        )
        .map((_) {}),
    revision: revision,
    check: client.checkConnection,
    syncDav: () async {
      dav = ref.read(libraryWebDavSyncProvider);
      late String applied;
      await dav!.sync(
        onApplied: () async {
          applied = await revision();
        },
      );
      return applied;
    },
    syncBangumi: () async {
      anime = ref.read(animeFollowSyncProvider);
      await anime!.syncBangumi(priority: AnimeSyncPriority.newest);
    },
    syncBangumiPriority: (priority) async {
      anime = ref.read(animeFollowSyncProvider);
      await anime!.syncBangumi(priority: priority);
    },
    cancel: () {
      dav?.dispose();
      anime?.cancel();
    },
  );
});

final libraryAutoSyncProvider =
    NotifierProvider<LibraryAutoSyncController, LibraryAutoSyncState>(
      LibraryAutoSyncController.new,
    );

/// Foreground-only, opt-out DAV sync. Network work never gates local writes.
class LibraryAutoSyncController extends Notifier<LibraryAutoSyncState> {
  static const enabledKey = 'sync.library.automatic';
  static const bangumiEnabledKey = 'sync.library.bangumiAutomatic';
  static const debounce = Duration(seconds: 10);
  static const maxWait = Duration(seconds: 30);
  static const pollInterval = Duration(minutes: 3);
  static const retryDelays = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 3),
  ];

  late Preferences _preferences;
  late WebDavConfig _config;
  LibraryAutoSyncRuntime? _runtime;
  StreamSubscription<void>? _changes;
  StreamSubscription<Object?>? _accounts;
  Timer? _quiet, _deadline, _poll, _retry;
  Future<void>? _flight, _probe;
  SourceRequestCancellation? _probeOwner;
  String? _revision;
  int _generation = 0, _attempt = 0;
  bool _disposed = false, _foreground = true, _blocked = false;
  bool _forceAgain = false;
  bool _bangumiBlocked = false;

  @override
  LibraryAutoSyncState build() {
    _preferences = ref.read(preferencesProvider);
    _config = ref.read(webDavConfigProvider);
    ref.listen(webDavConfigProvider, (_, next) => _switchConfig(next));
    _accounts = _preferences
        .watch('tracking.bangumi.credentialsRevision')
        .skip(1)
        .listen((_) => _accountChanged());
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _stopTimers();
      _probeOwner?.cancel();
      unawaited(_changes?.cancel());
      unawaited(_accounts?.cancel());
      _runtime?.cancel();
    });
    final initial = LibraryAutoSyncState(
      enabled: _preferences.get<bool>(enabledKey) ?? true,
      bangumiEnabled: _preferences.get<bool>(bangumiEnabledKey) ?? false,
      configured: _config.isConfigured,
      lastSuccess: _readLastSuccess(_config),
    );
    scheduleMicrotask(() {
      if (!_disposed) _start();
    });
    return initial;
  }

  bool get _canAuto =>
      state.enabled && state.configured || state.bangumiEnabled && _hasBangumi;
  bool get _hasBangumi =>
      (ref.read(secureStoreProvider).get('tracking.bangumi.token') ?? '')
          .isNotEmpty;

  String _endpointKey(WebDavConfig config) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            config.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
            config.remotePath.split('/').where((s) => s.isNotEmpty).join('/'),
            config.username,
          ]),
        ),
      )
      .toString();

  DateTime? _readLastSuccess(WebDavConfig config) {
    if (!config.isConfigured) return null;
    final raw = _preferences.get<String>(
      'sync.library.success.${_endpointKey(config)}',
    );
    return raw == null ? null : DateTime.tryParse(raw);
  }

  void _start({bool syncImmediately = true}) {
    if (!_canAuto || !_foreground || _disposed) return;
    _listenChanges();
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) {
      if (!_blocked) unawaited(_request(force: true));
    });
    if (syncImmediately) unawaited(_request(force: true));
  }

  void _listenChanges() {
    if (_changes != null) return;
    final LibraryAutoSyncRuntime runtime =
        _runtime ??
        ref.read<LibraryAutoSyncRuntime>(libraryAutoSyncRuntimeProvider);
    _runtime = runtime;
    _changes = runtime.changes.listen(
      (_) {
        if (_disposed || !_canAuto) return;
        state = state.copyWith(pending: true);
        if (_foreground && !_blocked && _retry == null) _schedule();
      },
      onError: (Object _) {
        if (!_disposed) state = state.copyWith(error: '读取本机同步数据失败，请重试');
      },
    );
  }

  void _schedule() {
    _quiet?.cancel();
    _quiet = Timer(debounce, () {
      _quiet = null;
      unawaited(_request());
    });
    _deadline ??= Timer(maxWait, () {
      _deadline = null;
      unawaited(_request());
    });
  }

  void _clearDebounce() {
    _quiet?.cancel();
    _quiet = null;
    _deadline?.cancel();
    _deadline = null;
  }

  void _stopTimers() {
    _clearDebounce();
    _poll?.cancel();
    _poll = null;
    _retry?.cancel();
    _retry = null;
  }

  void _switchConfig(WebDavConfig next) {
    if (_sameConfig(_config, next)) return;
    _resetOperation();
    _config = next;
    state = LibraryAutoSyncState(
      enabled: state.enabled,
      bangumiEnabled: state.bangumiEnabled,
      configured: next.isConfigured,
      lastSuccess: _readLastSuccess(next),
    );
    scheduleMicrotask(() {
      if (!_disposed) _start();
    });
  }

  void _accountChanged() {
    if (_disposed || !state.bangumiEnabled) return;
    _resetOperation();
    state = state.copyWith(
      syncing: false,
      checking: false,
      pending: false,
      clearBangumiError: true,
    );
    _start();
  }

  void _resetOperation() {
    _generation++;
    _stopTimers();
    _probeOwner?.cancel();
    _runtime?.cancel();
    unawaited(_changes?.cancel());
    if (_runtime != null) {
      ref.invalidate(libraryWebDavSyncProvider);
      ref.invalidate(animeFollowSyncProvider);
      ref.invalidate(animeCollectionServiceProvider);
      ref.invalidate(libraryAutoSyncRuntimeProvider);
    }
    _changes = null;
    _runtime = null;
    _flight = null;
    _probe = null;
    _revision = null;
    _attempt = 0;
    _blocked = false;
    _forceAgain = false;
    _bangumiBlocked = false;
  }

  Future<void> setEnabled(bool enabled) async {
    await _preferences.set(enabledKey, enabled);
    if (_disposed) return;
    if (state.enabled == enabled) return;
    _resetOperation();
    state = state.copyWith(
      enabled: enabled,
      syncing: false,
      checking: false,
      pending: false,
    );
    _start();
  }

  Future<void> setBangumiEnabled(bool enabled) async {
    await _preferences.set(bangumiEnabledKey, enabled);
    if (_disposed || state.bangumiEnabled == enabled) return;
    _resetOperation();
    state = state.copyWith(
      bangumiEnabled: enabled,
      syncing: false,
      checking: false,
      pending: false,
      clearBangumiError: true,
    );
    _start();
  }

  Future<void> checkConnection() {
    if (_disposed || !state.configured) return Future<void>.value();
    final existing = _probe;
    if (existing != null) return existing;
    final generation = _generation;
    final owner = _probeOwner = SourceRequestCancellation();
    final LibraryAutoSyncRuntime runtime =
        _runtime ??
        ref.read<LibraryAutoSyncRuntime>(libraryAutoSyncRuntimeProvider);
    _runtime = runtime;
    state = state.copyWith(checking: true);
    final operation = () async {
      try {
        await owner.run(() => runtime.check(_config));
        if (!_current(generation)) return;
        _blocked = false;
        state = state.copyWith(
          connected: true,
          checkedAt: DateTime.now(),
          clearError: true,
        );
      } catch (error) {
        if (!_current(generation)) return;
        _blocked = !_transient(error);
        state = state.copyWith(
          connected: false,
          checkedAt: DateTime.now(),
          pending: state.pending || state.syncing,
          error: _safeError(error),
        );
      } finally {
        if (_current(generation)) {
          state = state.copyWith(checking: false);
          _probe = null;
          _probeOwner = null;
        }
      }
    }();
    _probe = operation;
    return operation;
  }

  Future<void> syncNow() {
    if (_disposed) return Future<void>.value();
    _blocked = false;
    _attempt = 0;
    _bangumiBlocked = false;
    _retry?.cancel();
    _retry = null;
    return _request(force: true, manual: true, bangumi: false);
  }

  /// Uses the same single flight and real merge services as automatic sync.
  /// Services are independently optional; one failure never hides another.
  Future<void> syncFollows({
    required bool webDav,
    required bool bangumi,
    required AnimeSyncPriority priority,
  }) async {
    final generation = _generation;
    final existing = _flight;
    if (existing != null) await existing;
    if (!_current(generation) || !webDav && !bangumi) return;
    _blocked = false;
    _bangumiBlocked = false;
    _retry?.cancel();
    _retry = null;
    await _request(
      force: true,
      manual: true,
      dav: webDav,
      bangumi: bangumi,
      priority: priority,
    );
  }

  void cancelSync() {
    final stages = {
      for (final entry in state.stages.entries)
        entry.key: switch (entry.value.phase) {
          AnimeFollowSyncPhase.waiting ||
          AnimeFollowSyncPhase.running => const AnimeFollowSyncStep(
            AnimeFollowSyncPhase.cancelled,
            '已取消；已完成的更改保留',
          ),
          _ => entry.value,
        },
    };
    _resetOperation();
    state = state.copyWith(
      syncing: false,
      checking: false,
      pending: true,
      stages: stages,
    );
    // Restore future edits and polling, not the explicitly cancelled pass.
    _start(syncImmediately: false);
  }

  void onResumed() {
    if (_disposed) return;
    _foreground = true;
    _blocked = false;
    _attempt = 0;
    _bangumiBlocked = false;
    _retry?.cancel();
    _retry = null;
    _start();
  }

  void onPaused() {
    if (_disposed || !_foreground) return;
    _foreground = false;
    _stopTimers();
    if (_canAuto && state.pending && !_blocked) {
      unawaited(_request(pauseFlush: true));
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _request({
    bool force = false,
    bool manual = false,
    bool pauseFlush = false,
    bool? dav,
    bool? bangumi,
    AnimeSyncPriority priority = AnimeSyncPriority.newest,
  }) {
    if (_disposed ||
        (!manual && (!_canAuto || _blocked || !_foreground && !pauseFlush))) {
      return Future<void>.value();
    }
    if (!(dav ?? state.configured) && !(bangumi ?? state.bangumiEnabled)) {
      return Future<void>.value();
    }
    if (_flight != null) {
      // Manual presses join exactly the same flight. Resume/poll only require
      // another pass when a durable local mutation is still pending.
      _forceAgain |= force && !manual && state.pending;
      return _flight!;
    }
    _clearDebounce();
    final generation = _generation;
    final LibraryAutoSyncRuntime runtime =
        _runtime ??
        ref.read<LibraryAutoSyncRuntime>(libraryAutoSyncRuntimeProvider);
    _runtime = runtime;
    if (_canAuto) _listenChanges();
    final operation = _run(
      runtime,
      generation,
      force: force,
      davEnabled: dav ?? state.configured && (state.enabled || manual),
      bangumiEnabled: bangumi ?? state.bangumiEnabled,
      priority: priority,
    );
    _flight = operation;
    return operation;
  }

  Future<void> _run(
    LibraryAutoSyncRuntime runtime,
    int generation, {
    required bool force,
    required bool davEnabled,
    required bool bangumiEnabled,
    required AnimeSyncPriority priority,
  }) async {
    var failed = false;
    var davSucceeded = false, bangumiSucceeded = false;
    void stage(
      AnimeFollowSyncStage key,
      AnimeFollowSyncPhase phase, [
      String? message,
    ]) {
      if (!_current(generation)) return;
      state = state.copyWith(
        stages: {...state.stages, key: AnimeFollowSyncStep(phase, message)},
      );
    }

    Future<void> davSuccess(String applied) async {
      if (!_current(generation)) return;
      _revision = applied;
      final success = DateTime.now();
      state = state.copyWith(lastSuccess: success, clearError: true);
      await _preferences.set(
        'sync.library.success.${_endpointKey(_config)}',
        success.toUtc().toIso8601String(),
      );
    }

    void failure(Object error, {bool bangumi = false}) {
      failed = true;
      _clearDebounce();
      if (bangumi) {
        _bangumiBlocked = true;
        state = state.copyWith(bangumiError: _safeError(error, bangumi: true));
      } else {
        _blocked = !_transient(error);
        state = state.copyWith(
          error: _safeError(error),
          pending: true,
          connected: error is StateError ? state.connected : false,
        );
      }
      if (_transient(error)) _retryLater();
    }

    try {
      final before = await runtime.revision();
      if (!_current(generation)) return;
      if (!force && before == _revision) {
        state = state.copyWith(pending: false);
        return;
      }
      state = state.copyWith(
        syncing: true,
        pending: false,
        stages: {
          for (final key in AnimeFollowSyncStage.values)
            key: AnimeFollowSyncStep(
              switch (key) {
                    AnimeFollowSyncStage.webDav => davEnabled,
                    AnimeFollowSyncStage.bangumi => bangumiEnabled,
                    AnimeFollowSyncStage.upload => davEnabled && bangumiEnabled,
                  }
                  ? AnimeFollowSyncPhase.waiting
                  : AnimeFollowSyncPhase.skipped,
            ),
        },
      );
      if (davEnabled) {
        stage(AnimeFollowSyncStage.webDav, AnimeFollowSyncPhase.running);
        try {
          if (!state.configured) throw const FormatException('未配置 WebDAV');
          if (!state.connected) await checkConnection();
          if (!_current(generation)) return;
          if (!state.connected) {
            failed = true;
            if (!_blocked) _retryLater();
            stage(
              AnimeFollowSyncStage.webDav,
              AnimeFollowSyncPhase.failed,
              state.error,
            );
          } else {
            await davSuccess(await runtime.syncDav());
            if (!_current(generation)) return;
            davSucceeded = true;
            _blocked = false;
            stage(AnimeFollowSyncStage.webDav, AnimeFollowSyncPhase.succeeded);
          }
        } catch (error) {
          if (!_current(generation)) return;
          failure(error);
          stage(
            AnimeFollowSyncStage.webDav,
            AnimeFollowSyncPhase.failed,
            state.error,
          );
        }
      }
      if (!_current(generation)) return;
      if (bangumiEnabled && !_bangumiBlocked) {
        stage(AnimeFollowSyncStage.bangumi, AnimeFollowSyncPhase.running);
        try {
          if (!_hasBangumi) {
            throw const SourceException(
              sourceId: 'bangumi',
              type: SourceErrorType.auth,
              message: '请先连接 Bangumi 追踪账号',
            );
          }
          final operation = runtime.syncBangumiPriority;
          if (operation == null) {
            await runtime.syncBangumi();
          } else {
            await operation(priority);
          }
          if (!_current(generation)) return;
          bangumiSucceeded = true;
          state = state.copyWith(
            bangumiLastSuccess: DateTime.now(),
            clearBangumiError: true,
          );
          stage(AnimeFollowSyncStage.bangumi, AnimeFollowSyncPhase.succeeded);
        } catch (error) {
          if (!_current(generation)) return;
          failure(error, bangumi: true);
          stage(
            AnimeFollowSyncStage.bangumi,
            AnimeFollowSyncPhase.failed,
            state.bangumiError,
          );
        }
      } else if (bangumiEnabled) {
        stage(
          AnimeFollowSyncStage.bangumi,
          AnimeFollowSyncPhase.skipped,
          state.bangumiError,
        );
      }
      if (!_current(generation)) return;
      if (davEnabled && bangumiEnabled) {
        if (davSucceeded && bangumiSucceeded) {
          stage(AnimeFollowSyncStage.upload, AnimeFollowSyncPhase.running);
          try {
            await davSuccess(await runtime.syncDav());
            if (!_current(generation)) return;
            stage(AnimeFollowSyncStage.upload, AnimeFollowSyncPhase.succeeded);
          } catch (error) {
            if (!_current(generation)) return;
            failure(error);
            stage(
              AnimeFollowSyncStage.upload,
              AnimeFollowSyncPhase.failed,
              state.error,
            );
          }
        } else {
          stage(
            AnimeFollowSyncStage.upload,
            AnimeFollowSyncPhase.skipped,
            '前两步未全部完成；已完成的更改保留',
          );
        }
      } else if (bangumiSucceeded) {
        _revision = await runtime.revision();
      }
      if (!_current(generation)) return;
      final after = await runtime.revision();
      if (!_current(generation)) return;
      final changed = failed || _revision != null && after != _revision;
      state = state.copyWith(pending: changed);
      if (!failed) {
        _attempt = 0;
        _blocked = false;
        if (changed && _foreground && _canAuto) _schedule();
      }
    } catch (error) {
      if (!_current(generation)) return;
      failure(error);
    } finally {
      if (_current(generation)) {
        _flight = null;
        state = state.copyWith(syncing: false);
        if (_forceAgain) {
          _forceAgain = false;
          if (_foreground && _canAuto && !_blocked) _schedule();
        }
      }
    }
  }

  void _retryLater() {
    if (!_foreground || !_canAuto || _attempt >= retryDelays.length) return;
    _retry?.cancel();
    final delay = retryDelays[_attempt++];
    _retry = Timer(delay, () {
      _retry = null;
      _bangumiBlocked = false;
      unawaited(_request(force: true));
    });
  }

  static bool _sameConfig(WebDavConfig a, WebDavConfig b) =>
      a.baseUrl == b.baseUrl &&
      a.username == b.username &&
      a.password == b.password &&
      a.remotePath == b.remotePath &&
      a.allowInsecureHttp == b.allowInsecureHttp;

  static bool _transient(Object error) =>
      error is StateError ||
      error is TimeoutException ||
      error is SourceException &&
          {
            SourceErrorType.network,
            SourceErrorType.timeout,
            SourceErrorType.rateLimited,
          }.contains(error.type);

  static String _safeError(Object error, {bool bangumi = false}) {
    final name = bangumi ? 'Bangumi' : 'WebDAV';
    if (error is SourceException && error.type == SourceErrorType.auth) {
      return '$name 认证失败或权限不足，请检查账号后重试';
    }
    if (error is SourceException && error.type == SourceErrorType.rateLimited) {
      return '$name 请求额度已用尽，稍后自动重试';
    }
    if (error is StateError) return '$name 合并期间本机或云端有变化，将稍后重试';
    if (error is FormatException) return '$name 数据格式无效，未覆盖本机数据';
    return '$name 连接或同步失败，请检查网络后重试';
  }
}
