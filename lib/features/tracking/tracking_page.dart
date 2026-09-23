import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/tracking_models.dart';
import 'data/tracking_providers.dart';

/// 追踪账号：配置 Bangumi / AniList 的 access token，查看已绑定作品。
///
/// 两个服务的凭据**彼此隔离**（与来源账号同一条红线），token 存设置存储、
/// 不写日志、不随备份导出（备份的敏感键过滤已覆盖 `token`）。
class TrackingPage extends ConsumerStatefulWidget {
  const TrackingPage({super.key});

  @override
  ConsumerState<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends ConsumerState<TrackingPage> {
  final Map<TrackingServiceKind, TextEditingController> _controllers =
      <TrackingServiceKind, TextEditingController>{
        TrackingServiceKind.bangumi: TextEditingController(),
        TrackingServiceKind.anilist: TextEditingController(),
      };

  final Map<TrackingServiceKind, String> _status =
      <TrackingServiceKind, String>{};

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final service = ref.read(trackingServiceProvider);
    for (final kind in TrackingServiceKind.values) {
      final token = service.tokenOf(kind);
      if (token != null) {
        _controllers[kind]!.text = token;
        _status[kind] = '已配置（点「测试连接」确认可用）';
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bindings = ref.watch(allTrackingBindingsProvider);

    return PageScaffold(
      title: '追踪账号',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '进度上报',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '绑定作品后，阅读/播放进度会自动上报到所选服务。'
                  '远端进度比本地新时不会回退（只增不减）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          for (final kind in TrackingServiceKind.values)
            _serviceCard(context, kind),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('已绑定作品', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                bindings.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, _) => Text('读取失败：$error'),
                  data: (rows) => rows.isEmpty
                      ? Text(
                          '还没有绑定作品。在作品详情页点「追踪」即可绑定到 Bangumi / AniList。',
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : Column(
                          children: <Widget>[
                            for (final row in rows)
                              _bindingTile(context, row),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bindingTile(BuildContext context, TrackBindRow row) {
    final kind = TrackingServiceKind.parse(row.service);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.sync_alt, size: 20),
      title: Text(row.remoteId),
      subtitle: Text(
        '${kind?.label ?? row.service} · 远端条目 ${row.remoteTrackId}'
        '${row.syncedAt == null ? '' : ' · 最近同步 ${_formatTime(row.syncedAt!)}'}',
      ),
      trailing: IconButton(
        tooltip: '解绑',
        icon: const Icon(Icons.link_off, size: 20),
        onPressed: kind == null
            ? null
            : () async {
                await ref
                    .read(trackingServiceProvider)
                    .unbind(
                      sourceId: row.sourceId,
                      remoteId: row.remoteId,
                      kind: kind,
                    );
                ref.invalidate(allTrackingBindingsProvider);
              },
      ),
    );
  }

  Widget _serviceCard(BuildContext context, TrackingServiceKind kind) {
    final configured = _controllers[kind]!.text.trim().isNotEmpty;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(kind.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            kind == TrackingServiceKind.bangumi
                ? '到 bgm.tv 的「开放接口」页生成 Access Token（需要 write:collection 权限）。'
                : '到 anilist.co 设置里创建 Token（授权时勾选编辑列表）。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _controllers[kind],
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Access Token',
              hintText: '粘贴 token，只保存在本机',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              FilledButton(
                onPressed: _busy ? null : () => unawaited(_save(kind)),
                child: const Text('保存并测试连接'),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (configured)
                TextButton(
                  onPressed: _busy ? null : () => unawaited(_clear(kind)),
                  child: const Text('清除'),
                ),
            ],
          ),
          if (_status[kind] != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _status[kind]!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.md,
      AppSpacing.lg,
      0,
    ),
    child: AppCard(child: child),
  );

  Future<void> _save(TrackingServiceKind kind) async {
    final token = _controllers[kind]!.text.trim();
    if (token.isEmpty) {
      setState(() => _status[kind] = '请先粘贴 access token');
      return;
    }
    setState(() {
      _busy = true;
      _status[kind] = '正在测试连接…';
    });
    final service = ref.read(trackingServiceProvider);
    try {
      // 先落盘再校验：校验失败也保留，方便用户对照错误排查。
      await service.setToken(kind, token);
      final name = await service.verify(kind);
      if (!mounted) return;
      setState(() => _status[kind] = '连接正常：$name');
      ref.invalidate(allTrackingBindingsProvider);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status[kind] = '连接失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear(TrackingServiceKind kind) async {
    await ref.read(trackingServiceProvider).clearToken(kind);
    if (!mounted) return;
    setState(() {
      _controllers[kind]!.clear();
      _status[kind] = '已清除 ${kind.label} 的 token';
    });
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
