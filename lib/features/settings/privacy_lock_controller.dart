import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/preferences.dart';
import '../../core/storage/secure_store.dart';

enum PrivacyLockStatus { disabled, locked, unlocked, unavailable }

enum PrivacyLockResult {
  success,
  invalidPin,
  mismatch,
  wrongPin,
  rateLimited,
  unavailable,
  busy,
  cancelled,
}

/// PBKDF2-HMAC-SHA256, one 32-byte block. Production uses 600,000 iterations
/// off the UI isolate; there is no plaintext PIN in any persisted record.
Uint8List derivePrivacyPin(String pin, Uint8List salt, int iterations) {
  final hmac = Hmac(sha256, utf8.encode(pin));
  final input = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
  input[input.length - 1] = 1;
  var previous = hmac.convert(input).bytes;
  final result = Uint8List.fromList(previous);
  for (var i = 1; i < iterations; i++) {
    previous = hmac.convert(previous).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= previous[j];
    }
  }
  return result;
}

Uint8List _deriveInWorker(Map<String, Object> input) => derivePrivacyPin(
  input['pin']! as String,
  input['salt']! as Uint8List,
  input['iterations']! as int,
);

typedef PrivacyPinDeriver = Future<Uint8List> Function(
  String pin,
  Uint8List salt,
  int iterations,
);

Future<Uint8List> _derive(String pin, Uint8List salt, int iterations) => compute(
  _deriveInWorker,
  {'pin': pin, 'salt': salt, 'iterations': iterations},
);

class _ProtectedPin {
  const _ProtectedPin(this.salt, this.hash, this.failures, this.blockedUntil);
  final Uint8List salt;
  final Uint8List hash;
  final int failures;
  final int blockedUntil;

  static _ProtectedPin parse(String? raw) {
    if (raw == null) throw const FormatException('Missing protected PIN');
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['version'] != 1 ||
        value['iterations'] != PrivacyLockController.iterations ||
        value['failures'] is! int ||
        value['blockedUntil'] is! int ||
        (value['failures'] as int) < 0 ||
        (value['failures'] as int) > 1000000 ||
        (value['blockedUntil'] as int) < 0 ||
        value['salt'] is! String ||
        value['hash'] is! String) {
      throw const FormatException('Invalid protected PIN');
    }
    final salt = base64Decode(value['salt'] as String);
    final hash = base64Decode(value['hash'] as String);
    if (salt.length != 32 || hash.length != 32) {
      throw const FormatException('Invalid protected PIN size');
    }
    return _ProtectedPin(salt, hash, value['failures'] as int, value['blockedUntil'] as int);
  }

  String encode() => jsonEncode({
    'version': 1,
    'iterations': PrivacyLockController.iterations,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'failures': failures,
    'blockedUntil': blockedUntil,
  });

  _ProtectedPin attempts(int count, int until) => _ProtectedPin(salt, hash, count, until);
}

/// Device-local UI access control, deliberately separate from incognito.
/// Every verification reserves an attempt durably *before* checking the PIN.
/// Missing/corrupt/unreadable protected records never unlock an enabled gate.
class PrivacyLockController extends ChangeNotifier {
  PrivacyLockController({
    required Preferences preferences,
    required SecureStore Function() secureStore,
  }) : this._(preferences, secureStore, DateTime.now, _derive);

  @visibleForTesting
  PrivacyLockController.forTesting({
    required Preferences preferences,
    required SecureStore Function() secureStore,
    DateTime Function()? clock,
    PrivacyPinDeriver? derive,
  }) : this._(preferences, secureStore, clock ?? DateTime.now, derive ?? _derive);

  PrivacyLockController._(this._preferences, this._secureStore, this._clock, this._derivePin) {
    _reload();
  }

  // secure.* is excluded on both export and import by BackupService.
  static const enabledKey = 'secure.privacyLock.enabled';
  static const disablePendingKey = 'secure.privacyLock.disablePending';
  static const recordKey = 'privacyLock.record.v1';
  static const iterations = 600000;
  static const explanation =
      '应用隐私锁仅限制界面访问，与无痕模式不同。它不加密书架数据库、缓存或媒体，'
      '也不提供网络匿名。PIN 和锁设置仅保存在本机，不进入便携备份。'
      '遗忘 PIN 无法在应用内绕过或恢复；只能使用已知 PIN，或通过系统清除应用数据'
      '（会丢失本机数据，请谨慎）。';
  static const unavailableMessage =
      '隐私锁的本机安全记录不可用、丢失或损坏，应用保持锁定。'
      '请恢复此设备原有的系统安全存储或修复存储访问后重试。'
      '便携备份不包含 PIN，无法解除此锁；应用不会删除你的书架、历史或下载。';

  final Preferences _preferences;
  final SecureStore Function() _secureStore;
  final DateTime Function() _clock;
  final PrivacyPinDeriver _derivePin;
  PrivacyLockStatus _status = PrivacyLockStatus.disabled;
  _ProtectedPin? _record;
  bool _busy = false;
  bool _foreground = true;
  int _lockGeneration = 0;

  PrivacyLockStatus get status => _status;
  bool get enabled => _status != PrivacyLockStatus.disabled;
  bool get blocksAccess => _status == PrivacyLockStatus.locked || _status == PrivacyLockStatus.unavailable;
  bool get busy => _busy;
  Duration get retryAfter {
    final remaining = (_record?.blockedUntil ?? 0) - _clock().millisecondsSinceEpoch;
    return Duration(milliseconds: max(0, remaining));
  }

  void _reload() {
    try {
      // Do not touch secureStoreProvider in lock-disabled widget tests.
      final marker = _preferences.get<Object?>(enabledKey);
      final pendingDisable = _preferences.get<Object?>(disablePendingKey);
      if ((marker == null || marker == false) && pendingDisable != true) {
        _status = PrivacyLockStatus.disabled;
        _record = null;
        return;
      }
      if (marker != true && pendingDisable != true) throw const FormatException('Invalid enabled marker');
      _record = _ProtectedPin.parse(_secureStore().get(recordKey));
      _status = PrivacyLockStatus.locked;
    } catch (_) {
      _status = PrivacyLockStatus.unavailable;
      _record = null;
    }
  }

  Future<void> retryStorage() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _secureStore().init();
      _reload();
    } catch (_) {
      _status = PrivacyLockStatus.unavailable;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void onLifecycleChanged(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) lock();
  }

  void lock() {
    _lockGeneration++;
    if (_status == PrivacyLockStatus.unlocked) {
      _status = PrivacyLockStatus.locked;
      notifyListeners();
    }
  }

  static bool validPin(String value) => RegExp(r'^[0-9]{6,64}$').hasMatch(value);

  Future<PrivacyLockResult> _operation(Future<PrivacyLockResult> Function() action) async {
    if (_busy) return PrivacyLockResult.busy;
    _busy = true;
    notifyListeners();
    try {
      return await action();
    } catch (_) {
      // Setup only enables after a protected write has succeeded. If a marker
      // persistence fails, keep that record (the confirmed PIN still works).
      _reload();
      if (enabled) _status = PrivacyLockStatus.unavailable;
      return PrivacyLockResult.unavailable;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<_ProtectedPin> _newRecord(String pin) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
    final hash = await _derivePin(pin, salt, iterations);
    if (hash.length != 32) throw const FormatException('Invalid derived PIN');
    return _ProtectedPin(salt, hash, 0, 0);
  }

  Future<void> _save(_ProtectedPin record) async {
    final store = _secureStore();
    await store.init();
    final encoded = record.encode();
    await store.set(recordKey, encoded);
    if (store.get(recordKey) != encoded) throw StateError('Protected write unavailable');
    _record = record;
  }

  Future<PrivacyLockResult> enable(String pin, String confirmation) => _operation(() async {
    if (enabled) return PrivacyLockResult.unavailable;
    if (!validPin(pin)) return PrivacyLockResult.invalidPin;
    if (pin != confirmation) return PrivacyLockResult.mismatch;
    final generation = _lockGeneration;
    await _save(await _newRecord(pin));
    await _preferences.set(enabledKey, true);
    await _preferences.flush();
    _status = _foreground && generation == _lockGeneration
        ? PrivacyLockStatus.unlocked
        : PrivacyLockStatus.locked;
    return PrivacyLockResult.success;
  });

  Future<PrivacyLockResult> _verify(String pin) async {
    if (!enabled || _status == PrivacyLockStatus.unavailable) return PrivacyLockResult.unavailable;
    // Read again: an unavailable store must not be masked by a controller cache.
    _record = _ProtectedPin.parse(_secureStore().get(recordKey));
    if (retryAfter > Duration.zero) return PrivacyLockResult.rateLimited;
    final count = min(1000000, _record!.failures + 1);
    final delaySeconds = count < 5 ? 0 : min(3600, 30 * (1 << min(7, count - 5)));
    await _save(_record!.attempts(count, _clock().millisecondsSinceEpoch + delaySeconds * 1000));
    if (!validPin(pin)) return PrivacyLockResult.wrongPin;
    final actual = await _derivePin(pin, _record!.salt, iterations);
    var difference = actual.length ^ _record!.hash.length;
    for (var i = 0; i < min(actual.length, _record!.hash.length); i++) {
      difference |= actual[i] ^ _record!.hash[i];
    }
    if (difference != 0) return PrivacyLockResult.wrongPin;
    await _save(_record!.attempts(0, 0));
    return PrivacyLockResult.success;
  }

  Future<PrivacyLockResult> unlock(String pin) => _operation(() async {
    final generation = _lockGeneration;
    final result = await _verify(pin);
    if (result == PrivacyLockResult.success && _foreground && generation == _lockGeneration) {
      _status = PrivacyLockStatus.unlocked;
    }
    return result;
  });

  Future<PrivacyLockResult> changePin(String current, String next, String confirmation) => _operation(() async {
    final generation = _lockGeneration;
    if (!validPin(next)) return PrivacyLockResult.invalidPin;
    if (next != confirmation) return PrivacyLockResult.mismatch;
    final result = await _verify(current);
    if (result != PrivacyLockResult.success) return result;
    if (!_foreground || generation != _lockGeneration) return PrivacyLockResult.cancelled;
    final previous = _record!;
    final record = await _newRecord(next);
    if (!_foreground || generation != _lockGeneration) return PrivacyLockResult.cancelled;
    await _save(record);
    if (!_foreground || generation != _lockGeneration) {
      await _save(previous);
      _status = PrivacyLockStatus.locked;
      return PrivacyLockResult.cancelled;
    }
    return PrivacyLockResult.success;
  });

  Future<PrivacyLockResult> disable(String current) => _operation(() async {
    final generation = _lockGeneration;
    final result = await _verify(current);
    if (result != PrivacyLockResult.success) return result;
    if (!_foreground || generation != _lockGeneration) return PrivacyLockResult.cancelled;
    // A durable pending marker keeps a cold restart locked if backgrounding
    // interrupts the asynchronous marker commit. Keep the PIN until finalized.
    await _preferences.set(disablePendingKey, true);
    await _preferences.flush();
    if (!_foreground || generation != _lockGeneration) return PrivacyLockResult.cancelled;
    await _preferences.set(enabledKey, false);
    await _preferences.flush();
    if (_foreground && generation == _lockGeneration) {
      await _preferences.remove(disablePendingKey);
      await _preferences.flush();
    }
    if (!_foreground || generation != _lockGeneration) {
      await _preferences.set(enabledKey, true);
      await _preferences.flush();
      await _preferences.remove(disablePendingKey);
      await _preferences.flush();
      _status = PrivacyLockStatus.locked;
      return PrivacyLockResult.cancelled;
    }
    final previous = _record!;
    await _secureStore().remove(recordKey);
    if (!_foreground || generation != _lockGeneration) {
      await _save(previous);
      await _preferences.set(enabledKey, true);
      await _preferences.flush();
      _status = PrivacyLockStatus.locked;
      return PrivacyLockResult.cancelled;
    }
    _status = PrivacyLockStatus.disabled;
    _record = null;
    return PrivacyLockResult.success;
  });
}

final privacyLockProvider = Provider<PrivacyLockController>((ref) {
  final controller = PrivacyLockController(
    preferences: ref.watch(preferencesProvider),
    secureStore: () => ref.read(secureStoreProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
