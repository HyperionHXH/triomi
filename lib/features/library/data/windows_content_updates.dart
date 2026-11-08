import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../../core/backup/backup_artifact_recovery.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/source/source_catalog.dart';
import '../../../core/source/windows_mihon_host.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import '../../schedule/data/background_update_check.dart';
import '../../sources/catalog_sheet.dart';
import 'manga_update_background.dart';
import 'manga_update_service.dart';

const _channel = MethodChannel('triomi/platform');
const windowsContentInterval = Duration(hours: 12);
const windowsContentScheduleErrorKey = 'content.updates.scheduleError';
const windowsContentBehaviorDescription =
    '约每 12 小时及登录后检查；应用关闭且当前用户已登录时由 Windows 任务计划程序运行，'
    '应用打开时由应用检查。非计费网络包括有线网络；系统勿扰或通知设置可能阻止桌面提醒。';
const _mangaEnabledKey = 'manga.updates.background';
const _animeCompletedKey = 'content.updates.animeCompleted';
const _mangaCompletedKey = 'content.updates.mangaCompleted';
final _schedulers = Expando<_ContentScheduler>();

/// Always send both persisted switches. Registration failure never silently
/// changes either choice; an old task also re-reads both choices before work.
Future<bool> reconcileWindowsContentUpdateSchedule(Preferences prefs) =>
    (_schedulers[prefs] ??= _ContentScheduler(prefs)).reconcile();

class _ContentScheduler {
  _ContentScheduler(this.prefs);
  final Preferences prefs;
  Future<void> _previous = Future<void>.value();
  Future<bool> reconcile() {
    final result = _previous.then((_) async {
      try {
        final registered = await _channel.invokeMethod<bool>(
          'scheduleMangaUpdates',
          {
            'backgroundCheck':
                prefs.get<bool>(backgroundCheckPreferenceKey) ?? false,
            'mangaUpdates': prefs.get<bool>(_mangaEnabledKey) ?? false,
          },
        );
        if (registered != true) {
          throw StateError('Registration failed');
        }
        await prefs.remove(windowsContentScheduleErrorKey);
        await prefs.flush();
        return true;
      } catch (_) {
        await prefs.set(
          windowsContentScheduleErrorKey,
          'Windows 后台更新排程失败；偏好已保留，应用内检查仍可用，请检查任务计划程序后重试',
        );
        await prefs.flush();
        return false;
      }
    });
    _previous = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Cooperative cancellation is checked before commits and every download chunk
/// by the production services, not merely at the next timer tick.
class WindowsContentUpdateCancellation {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  final _listeners = <void Function()>{};
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

typedef WindowsContentUpdateRun = Future<void> Function(
  WindowsContentUpdateCancellation cancellation,
);

/// Native owns a bounded serial queue. This future resolves only after Windows
/// reports presentation and completion, never merely Shell_NotifyIcon acceptance.
Future<void> notifyWindowsContentUpdate({
  required String title,
  required String body,
}) async {
  if (await const MethodChannel('triomi/content-notifications')
          .invokeMethod<bool>('notify', {'title': title, 'body': body}) != true) {
    throw StateError('Desktop notification was not presented');
  }
}

/// One flight for startup, timer and resume. Public injection points let tests
/// exercise real preference/coalescing/cancellation behavior without a network.
class WindowsContentUpdateCoordinator {
  WindowsContentUpdateCoordinator({
    required this.preferences,
    required this.runAnime,
    required this.runManga,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Preferences preferences;
  final WindowsContentUpdateRun runAnime, runManga;
  final DateTime Function() now;
  Future<void>? _flight;
  WindowsContentUpdateCancellation? _cancellation;
  bool _disposed = false;
  Future<void>? get currentRun => _flight;

  void cancel() => _cancellation?.cancel();
  Future<void> dispose() async {
    _disposed = true;
    cancel();
    await _flight;
  }

  Future<void> run({bool force = false}) {
    if (_disposed) {
      return Future<void>.value();
    }
    if (_flight case final running?) {
      return running;
    }
    final token = WindowsContentUpdateCancellation();
    _cancellation = token;
    final completer = Completer<void>();
    _flight = completer.future;
    () async {
      try {
        await _runOne(
          backgroundCheckPreferenceKey,
          _animeCompletedKey,
          runAnime,
          token,
          force,
        );
        await _runOne(
          _mangaEnabledKey,
          _mangaCompletedKey,
          runManga,
          token,
          force,
        );
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _flight = null;
        _cancellation = null;
      }
    }();
    return completer.future;
  }

  Future<void> _runOne(
    String enabledKey,
    String completedKey,
    WindowsContentUpdateRun execute,
    WindowsContentUpdateCancellation token,
    bool force,
  ) async {
    if (_disposed ||
        token.cancelled ||
        preferences.get<bool>(enabledKey) != true) {
      return;
    }
    final last = DateTime.tryParse(preferences.get<String>(completedKey) ?? '');
    final time = now();
    if (!force &&
        last != null &&
        !last.isAfter(time) &&
        time.difference(last) < windowsContentInterval) {
      return;
    }
    await preferences.set('$completedKey.attempt', time.toIso8601String());
    try {
      await execute(token);
      if (!token.cancelled && preferences.get<bool>(enabledKey) == true) {
        await preferences.set(completedKey, now().toIso8601String());
        await preferences.remove('$completedKey.error');
      }
    } catch (_) {
      // Never persist raw exceptions: source/proxy errors can contain credentials.
      await preferences.set(
        '$completedKey.error',
        '后台内容检查未完成；目录与进度保留，请检查来源、网络、通知设置和存储后重试',
      );
    } finally {
      await preferences.flush();
    }
  }
}

WindowsContentUpdateCoordinator _productionCoordinator(
  ProviderContainer container,
  Preferences prefs, {
  bool foreground = false,
}) {
  bool enabled(String key, WindowsContentUpdateCancellation token) =>
      !token.cancelled && prefs.get<bool>(key) == true;
  return WindowsContentUpdateCoordinator(
    preferences: prefs,
    runAnime: (token) async {
      if (await _channel.invokeMethod<bool>('mangaUpdateConstraints', {
            'wifiOnly': true,
            'batteryNotLow': false,
          }) !=
          true) {
        throw StateError('Network constraints not satisfied');
      }
      final result = await runBackgroundUpdateCheck(container);
      if (result == null || !enabled(backgroundCheckPreferenceKey, token)) {
        return;
      }
      // Daily de-duplication also spans logon, task retries and foreground runs.
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final identity = '$today:${result.titles.join('\u0000')}';
      if (prefs.get<String>('content.updates.animeNotified') == identity) {
        return;
      }
      if (await _channel.invokeMethod<bool>('canNotifyContentUpdates') !=
          true) {
        throw StateError('Notification not currently available');
      }
      await notifyWindowsContentUpdate(
        title: 'anime updates',
        body: result.notificationBody,
      );
      await prefs.set('content.updates.animeNotified', identity);
    },
    runManga: (token) async {
      final options = MangaUpdateOptions.load(prefs);
      if (await _channel.invokeMethod<bool>(
            'mangaUpdateConstraints',
            options.toJson(),
          ) !=
          true) {
        throw StateError('Network/battery constraints not satisfied');
      }
      await runMangaUpdates(
        container,
        shouldContinue: () => enabled(_mangaEnabledKey, token),
        foreground: foreground,
        cancellation: token,
      );
    },
  );
}

/// Native must acquire ProfileOwnership before starting this engine. No account
/// migration/onboarding/sync runs here; credentials are only opened for reading.
Future<void> runWindowsContentUpdatesEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase? database;
  ProviderContainer? container;
  Preferences? prefs;
  var success = true;
  try {
    await Hive.initFlutter();
    prefs = await Preferences.open();
    if (prefs.get<bool>(backgroundCheckPreferenceKey) != true &&
        prefs.get<bool>(_mangaEnabledKey) != true) {
      return;
    }
    final secure = FlutterSecureStore();
    await secure.init();
    database = AppDatabase();
    if (!await BackupArtifactRecovery.recoverBeforeUse(database, prefs)) {
      throw StateError('Profile recovery incomplete');
    }
    await WindowsMihonHost.instance.configureProxy(
      prefs.get<String>('network.sourceProxy') ?? '',
    );
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
        secureStoreProvider.overrideWithValue(secure),
        sourceCatalogLoaderProvider.overrideWith(
          (ref) =>
              () async => SourceCatalogIndex.parse(
                await rootBundle.loadString('assets/catalog/index.json'),
              ),
        ),
      ],
    );
    final coordinator = _productionCoordinator(container, prefs);
    try {
      await coordinator.run();
      success =
          (prefs.get<bool>(backgroundCheckPreferenceKey) != true ||
              prefs.get<String>('$_animeCompletedKey.error') == null) &&
          (prefs.get<bool>(_mangaEnabledKey) != true ||
              prefs.get<String>('$_mangaCompletedKey.error') == null);
      if (success) {
        await prefs.remove('content.updates.lastError');
      }
    } finally {
      await coordinator.dispose();
    }
  } catch (_) {
    success = false;
    await prefs?.set(
      'content.updates.lastError',
      'Windows 后台内容检查初始化失败；请打开应用检查来源、网络及本地存储',
    );
  } finally {
    try {
      await prefs?.flush();
      container?.dispose();
      await database?.close();
      await Hive.close();
    } catch (_) {
      success = false;
    } finally {
      await _channel.invokeMethod<void>('completeContentUpdates', success);
    }
  }
}

/// Read once inside the foreground ProviderScope, AFTER preference/database
/// overrides exist. This container is the sole database owner while UI is open.
final windowsContentUpdatesProvider = Provider<WindowsContentUpdatesRuntime?>((
  ref,
) {
  if (!Platform.isWindows) {
    return null;
  }
  final prefs = ref.watch(preferencesProvider);
  final container = ref.container;
  final runtime = WindowsContentUpdatesRuntime(
    _productionCoordinator(container, prefs, foreground: true),
    prefs,
  );
  runtime.start();
  ref.onDispose(runtime.dispose);
  return runtime;
});

class WindowsContentUpdatesRuntime with WidgetsBindingObserver {
  WindowsContentUpdatesRuntime(this.coordinator, this.preferences);
  final WindowsContentUpdateCoordinator coordinator;
  final Preferences preferences;
  Timer? _timer;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _disposed = false;
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(windowsContentInterval, (_) => _run());
    for (final key in [
      backgroundCheckPreferenceKey,
      _mangaEnabledKey,
      'manga.updates.options',
    ]) {
      // Preferences.watch emits an initial value; startup already handles it.
      _subscriptions.add(
        preferences.watch(key).skip(1).listen((_) {
          final previous = coordinator.currentRun;
          coordinator.cancel();
          unawaited(_settingsChanged(previous: previous));
        }),
      );
    }
    unawaited(_settingsChanged());
  }

  Future<void> _settingsChanged({Future<void>? previous}) async {
    try {
      await reconcileWindowsContentUpdateSchedule(preferences);
      // Only wait for an older cancelled flight, never run a failed new flight
      // twice on one startup/settings event.
      await previous;
      if (!_disposed) {
        await coordinator.run();
      }
    } catch (_) {
      // Scheduling and run errors are persisted by their owning operations.
    }
  }

  void _run() {
    if (!_disposed) unawaited(coordinator.run());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _run();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(coordinator.dispose());
  }
}
