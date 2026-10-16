import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/windows_source_session.dart';

import 'privacy_lock_controller.dart';
import 'privacy_lock_settings_page.dart';

/// Root dispatcher must be above the routed Navigator: a route-local PopScope
/// cannot stop deep links or Back dispatched to a sibling navigator.
class PrivacyLockBackButtonDispatcher extends RootBackButtonDispatcher {
  PrivacyLockBackButtonDispatcher(this.lock);
  final PrivacyLockController lock;

  @override
  Future<bool> didPopRoute() => lock.blocksAccess ? SynchronousFuture(true) : super.didPopRoute();
}

/// Keeps an already-open reader/player mounted while excluding all of its
/// pixels, focus, accessibility and pointer interaction. A cold locked start
/// does not mount the routed child at all, so a deep link cannot start media.
class PrivacyLockGate extends ConsumerStatefulWidget {
  const PrivacyLockGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PrivacyLockGate> createState() => _PrivacyLockGateState();
}

class _PrivacyLockGateState extends ConsumerState<PrivacyLockGate> with WidgetsBindingObserver {
  late final PrivacyLockController _lock;
  bool _hasExposedChild = false;
  bool? _nativeProtected;
  bool? _nativeBlocked;
  bool? _windowsBlocked;
  bool? _windowsProtected;

  @override
  void initState() {
    super.initState();
    _lock = ref.read(privacyLockProvider);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null) _lock.onLifecycleChanged(lifecycle);
    _lock.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _synchronizeNative();
  }

  void _synchronizeNative() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows &&
        (_windowsBlocked != _lock.blocksAccess || _windowsProtected != _lock.enabled)) {
      _windowsBlocked = _lock.blocksAccess;
      _windowsProtected = _lock.enabled;
      unawaited(WindowsSourceSession.setBlocked(
        _lock.blocksAccess, protected: _lock.enabled,
      ).catchError((Object _) {}));
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android ||
        (_nativeProtected == _lock.enabled && _nativeBlocked == _lock.blocksAccess)) {
      return;
    }
    _nativeProtected = _lock.enabled;
    _nativeBlocked = _lock.blocksAccess;
    unawaited(const MethodChannel('triomi/privacy-lock').invokeMethod<void>('protect', {
      'enabled': _lock.enabled,
      'blocked': _lock.blocksAccess,
    }).catchError((Object _) {}));
  }

  void _changed() {
    _synchronizeNative();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _lock.onLifecycleChanged(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lock.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lock.blocksAccess;
    if (!locked) _hasExposedChild = true;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_hasExposedChild)
          Offstage(
            offstage: locked,
            child: TickerMode(
              enabled: !locked,
              child: ExcludeFocus(
                excluding: locked,
                child: ExcludeSemantics(
                  excluding: locked,
                  child: IgnorePointer(ignoring: locked, child: widget.child),
                ),
              ),
            ),
          ),
        if (locked) Positioned.fill(child: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => _PrivacyUnlockPage(controller: _lock),
          ),
        )),
      ],
    );
  }
}

class _PrivacyUnlockPage extends StatefulWidget {
  const _PrivacyUnlockPage({required this.controller});
  final PrivacyLockController controller;

  @override
  State<_PrivacyUnlockPage> createState() => _PrivacyUnlockPageState();
}

class _PrivacyUnlockPageState extends State<_PrivacyUnlockPage> {
  final _pin = TextEditingController();
  String? _message;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final value = _pin.text;
    _pin.clear();
    final result = await widget.controller.unlock(value);
    if (!mounted) return;
    setState(() => _message = privacyLockResultMessage(result));
  }

  @override
  Widget build(BuildContext context) {
    final lock = widget.controller;
    return FocusScope(
      autofocus: true,
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: '应用已锁定',
        child: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      const Icon(Icons.lock_outline, size: 48, semanticLabel: '隐私锁'),
                      const SizedBox(height: 16),
                      Text('应用已锁定', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      if (lock.status == PrivacyLockStatus.unavailable) ...[
                        const Text(PrivacyLockController.unavailableMessage),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: lock.busy ? null : lock.retryStorage, child: const Text('重试安全存储')),
                      ] else ...[
                        PrivacyPinField(
                          controller: _pin,
                          label: '输入 PIN 解锁',
                          autofocus: true,
                          enabled: !lock.busy,
                          onSubmitted: (_) { if (!lock.busy) _unlock(); },
                        ),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: lock.busy ? null : _unlock, child: const Text('解锁')),
                        PrivacyLockRetryLabel(controller: lock),
                      ],
                      if (lock.busy) Semantics(label: '正在验证 PIN', child: const LinearProgressIndicator()),
                      if (_message != null) Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Semantics(liveRegion: true, child: Text(_message!)),
                      ),
                      const SizedBox(height: 24),
                      const Text('仅使用本机 PIN 解锁。不提供跳过或无 PIN 恢复；不会清除你的数据。'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
