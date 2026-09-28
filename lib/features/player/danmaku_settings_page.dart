import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/danmaku_settings.dart';

/// 弹幕设置页：显示参数 + 屏蔽词 + 弹弹play 凭据（不落日志）。
class DanmakuSettingsPage extends ConsumerStatefulWidget {
  const DanmakuSettingsPage({super.key});

  @override
  ConsumerState<DanmakuSettingsPage> createState() =>
      _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends ConsumerState<DanmakuSettingsPage> {
  final TextEditingController _wordController = TextEditingController();
  final TextEditingController _appIdController = TextEditingController();
  final TextEditingController _appSecretController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _userNameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _credentialsLoaded = false;
  bool _loggingIn = false;

  @override
  void initState() {
    super.initState();
    final credentials = ref.read(dandanplayCredentialsProvider);
    _appIdController.text = credentials.appId;
    _appSecretController.text = credentials.appSecret;
    _tokenController.text = credentials.token;
    _credentialsLoaded = true;
  }

  @override
  void dispose() {
    _wordController.dispose();
    _appIdController.dispose();
    _appSecretController.dispose();
    _tokenController.dispose();
    _userNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(danmakuSettingsProvider);
    final credentials = ref.watch(dandanplayCredentialsProvider);
    final controller = ref.read(danmakuSettingsProvider.notifier);

    return PageScaffold(
      title: '弹幕设置',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          _Section(
            title: '显示',
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示弹幕'),
                value: settings.enabled,
                onChanged: (value) => unawaited(
                  controller.update(settings.copyWith(enabled: value)),
                ),
              ),
              _slider(
                context,
                label: '不透明度',
                value: settings.opacity,
                min: 0.2,
                max: 1.0,
                divisions: 8,
                labelText: '${(settings.opacity * 100).round()}%',
                onChanged: (value) => unawaited(
                  controller.update(settings.copyWith(opacity: value)),
                ),
              ),
              _slider(
                context,
                label: '字号',
                value: settings.fontScale,
                min: 0.6,
                max: 1.6,
                divisions: 10,
                labelText: '${settings.fontScale.toStringAsFixed(1)}x',
                onChanged: (value) => unawaited(
                  controller.update(settings.copyWith(fontScale: value)),
                ),
              ),
              _slider(
                context,
                label: '速度',
                value: settings.speedScale,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                labelText: '${settings.speedScale.toStringAsFixed(1)}x',
                onChanged: (value) => unawaited(
                  controller.update(settings.copyWith(speedScale: value)),
                ),
              ),
              Wrap(
                spacing: AppSpacing.xs,
                children: <Widget>[
                  FilterChip(
                    label: const Text('滚动'),
                    selected: settings.showScroll,
                    onSelected: (value) => unawaited(
                      controller.update(settings.copyWith(showScroll: value)),
                    ),
                  ),
                  FilterChip(
                    label: const Text('顶部'),
                    selected: settings.showTop,
                    onSelected: (value) => unawaited(
                      controller.update(settings.copyWith(showTop: value)),
                    ),
                  ),
                  FilterChip(
                    label: const Text('底部'),
                    selected: settings.showBottom,
                    onSelected: (value) => unawaited(
                      controller.update(settings.copyWith(showBottom: value)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          _Section(
            title: '屏蔽词',
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _wordController,
                      decoration: const InputDecoration(hintText: '输入屏蔽词后回车'),
                      onSubmitted: (_) => _addWord(settings),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _addWord(settings),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (settings.blockedWords.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    '还没有屏蔽词',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                Wrap(
                  spacing: AppSpacing.xs,
                  children: <Widget>[
                    for (final word in settings.blockedWords)
                      InputChip(
                        label: Text(word),
                        onDeleted: () => unawaited(
                          controller.update(
                            settings.copyWith(
                              blockedWords: <String>[
                                for (final item in settings.blockedWords)
                                  if (item != word) item,
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          _Section(
            title: '弹弹play 凭据',
            children: <Widget>[
              Text(
                DandanplayCredentials.hasBuiltIn
                    ? '应用已内置弹幕凭据，拉取弹幕开箱可用；填自己的 AppId / AppSecret 可覆盖。'
                          '发送弹幕还需要账号 token。来源规则自带弹幕源时无需任何凭据。'
                          '凭据只保存在本机设置里，不写日志、不随备份导出。'
                    : '弹幕匹配（拉取弹幕）用 AppId / AppSecret，到弹弹play 开放平台申请后填入；'
                          '发送弹幕还需要账号 token。来源规则自带弹幕源时无需任何凭据。'
                          '凭据只保存在本机设置里，不写日志、不随备份导出。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _appIdController,
                decoration: const InputDecoration(labelText: 'AppId'),
              ),
              TextField(
                controller: _appSecretController,
                decoration: const InputDecoration(labelText: 'AppSecret'),
                obscureText: true,
              ),
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(labelText: '账号 token（发送弹幕用）'),
                obscureText: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  FilledButton(
                    onPressed: _credentialsLoaded ? _saveCredentials : null,
                    child: const Text('保存凭据'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    credentials.canSend
                        ? '可拉取、可发送'
                        : (credentials.isConfigured
                              ? '仅可拉取（未配置账号 token）'
                              : '未配置'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '没有现成 token？填 AppId / AppSecret 后用账号密码登录自动获取'
                '（密码只用于本次登录请求，不保存）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _userNameController,
                      decoration: const InputDecoration(labelText: '账号'),
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _passwordController,
                      decoration: const InputDecoration(labelText: '密码'),
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: (_) => unawaited(_loginForToken()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  OutlinedButton(
                    onPressed: _loggingIn ? null : _loginForToken,
                    child: Text(_loggingIn ? '登录中…' : '登录获取 token'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String labelText,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('$label $labelText', style: Theme.of(context).textTheme.bodySmall),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    ],
  );

  void _addWord(DanmakuSettings settings) {
    final word = _wordController.text.trim();
    if (word.isEmpty || settings.blockedWords.contains(word)) {
      _wordController.clear();
      return;
    }
    unawaited(
      ref
          .read(danmakuSettingsProvider.notifier)
          .update(
            settings.copyWith(
              blockedWords: <String>[...settings.blockedWords, word],
            ),
          ),
    );
    _wordController.clear();
  }

  /// 账号密码登录拿 token：成功后写回凭据并清空密码框。
  ///
  /// 密码只在请求里用一次，不落盘、不进任何回调日志。
  Future<void> _loginForToken() async {
    if (_loggingIn) return;
    final userName = _userNameController.text.trim();
    final password = _passwordController.text;
    if (userName.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('先填账号与密码')));
      return;
    }
    // 先保存当前凭据输入（登录要用 AppId / AppSecret 签名）。
    await _saveCredentials();
    setState(() => _loggingIn = true);
    try {
      final token = await ref
          .read(dandanplayCredentialsProvider.notifier)
          .login(userName, password);
      if (!mounted) return;
      _tokenController.text = token ?? '';
      _passwordController.clear();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('登录成功，token 已写入')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('登录失败：$error')));
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _saveCredentials() async {
    final next = DandanplayCredentials(
      appId: _appIdController.text.trim(),
      appSecret: _appSecretController.text.trim(),
      token: _tokenController.text.trim(),
    );
    await ref.read(dandanplayCredentialsProvider.notifier).update(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('凭据已保存')));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.md,
      AppSpacing.lg,
      0,
    ),
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          ...children,
        ],
      ),
    ),
  );
}
