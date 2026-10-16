import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'privacy_lock_controller.dart';

String privacyLockResultMessage(PrivacyLockResult result) => switch (result) {
  PrivacyLockResult.success => '操作已完成',
  PrivacyLockResult.invalidPin => 'PIN 必须为 6 至 64 位数字',
  PrivacyLockResult.mismatch => '两次输入的 PIN 不一致',
  PrivacyLockResult.wrongPin => 'PIN 不正确',
  PrivacyLockResult.rateLimited => '尝试过于频繁，请等待下方倒计时结束',
  PrivacyLockResult.unavailable => '本机安全存储操作失败，未能完成操作；请检查锁定状态后重试',
  PrivacyLockResult.busy => '正在处理，请稍候',
  PrivacyLockResult.cancelled => '应用已重新锁定，本次修改已取消；解锁后请重新验证 PIN',
};

/// Labeled, obscured PIN entry, never suggested, spellchecked or autofilled.
class PrivacyPinField extends StatelessWidget {
  const PrivacyPinField({
    super.key,
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.enabled = true,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    keyboardType: TextInputType.number,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    autofillHints: const [],
    autofocus: autofocus,
    enabled: enabled,
    maxLength: 64,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onSubmitted: onSubmitted,
  );
}

/// Timer exists only on this visible label, not on the application root.
class PrivacyLockRetryLabel extends StatefulWidget {
  const PrivacyLockRetryLabel({super.key, required this.controller});
  final PrivacyLockController controller;

  @override
  State<PrivacyLockRetryLabel> createState() => _PrivacyLockRetryLabelState();
}

class _PrivacyLockRetryLabelState extends State<PrivacyLockRetryLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    _update();
  }

  void _update() {
    _timer?.cancel();
    if (widget.controller.retryAfter > Duration.zero) {
      _timer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(_update);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (widget.controller.retryAfter.inMilliseconds / 1000).ceil();
    return seconds > 0 ? Text('请在 $seconds 秒后重试') : const SizedBox.shrink();
  }
}

class PrivacyLockSettingsPage extends ConsumerStatefulWidget {
  const PrivacyLockSettingsPage({super.key});

  @override
  ConsumerState<PrivacyLockSettingsPage> createState() => _PrivacyLockSettingsPageState();
}

class _PrivacyLockSettingsPageState extends ConsumerState<PrivacyLockSettingsPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirmation = TextEditingController();
  String? _message;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit(Future<PrivacyLockResult> Function() action) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await action();
    if (!mounted) return;
    // Forget transient PIN inputs after every attempt, including failures.
    _current.clear();
    _next.clear();
    _confirmation.clear();
    setState(() => _message = privacyLockResultMessage(result));
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(privacyLockProvider);
    return AnimatedBuilder(
      animation: lock,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('应用隐私锁')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(lock.enabled ? '隐私锁已开启' : '隐私锁未开启', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    const Text(PrivacyLockController.explanation),
                    const SizedBox(height: 12),
                    const Text('开启后，每次冷启动或离开应用（包含后台、窗口失焦、系统对话框）都会锁定。'
                        '不会改变无痕设置或删除原有数据。Android 开启时禁止截图与画中画；'
                        '其他平台不保证阻止系统截图。请使用不易猜测的 PIN。'),
                    const SizedBox(height: 24),
                    if (lock.status == PrivacyLockStatus.unavailable) ...[
                      const Text(PrivacyLockController.unavailableMessage),
                      TextButton(onPressed: lock.busy ? null : lock.retryStorage, child: const Text('重试安全存储')),
                    ] else ...[
                      if (lock.enabled) ...[
                        PrivacyPinField(controller: _current, label: '当前 PIN（修改或关闭必须填写）', enabled: !lock.busy),
                        const SizedBox(height: 16),
                      ],
                      PrivacyPinField(controller: _next, label: lock.enabled ? '新 PIN（6 至 64 位数字）' : '设置 PIN（6 至 64 位数字）', enabled: !lock.busy),
                      const SizedBox(height: 16),
                      PrivacyPinField(controller: _confirmation, label: '再次输入新 PIN', enabled: !lock.busy),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: lock.busy ? null : () => _submit(() => lock.enabled
                            ? lock.changePin(_current.text, _next.text, _confirmation.text)
                            : lock.enable(_next.text, _confirmation.text)),
                        child: Text(lock.enabled ? '验证当前 PIN 并修改' : '确认并开启隐私锁'),
                      ),
                      if (lock.enabled) ...[
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: lock.busy ? null : () => _submit(() => lock.disable(_current.text)),
                          child: const Text('验证当前 PIN 并关闭'),
                        ),
                        TextButton(onPressed: lock.busy ? null : lock.lock, child: const Text('立即锁定')),
                      ],
                    ],
                    PrivacyLockRetryLabel(controller: lock),
                    if (lock.busy) Semantics(label: '正在保护 PIN', child: const LinearProgressIndicator()),
                    if (_message != null) Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Semantics(liveRegion: true, child: Text(_message!)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
