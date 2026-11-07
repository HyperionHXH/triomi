import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/storage/secure_store.dart';
import '../library/data/library_auto_sync.dart';
import 'data/anime_follow_sync.dart';

Future<void> showAnimeFollowSyncDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AnimeFollowSyncDialog(),
    );

class AnimeFollowSyncDialog extends ConsumerStatefulWidget {
  const AnimeFollowSyncDialog({super.key});
  @override
  ConsumerState<AnimeFollowSyncDialog> createState() =>
      _AnimeFollowSyncDialogState();
}

class _AnimeFollowSyncDialogState extends ConsumerState<AnimeFollowSyncDialog> {
  bool _dav = false, _bangumi = false, _started = false, _running = false;
  bool _cancelled = false;
  String? _settingsError;
  AnimeSyncPriority _priority = AnimeSyncPriority.local;

  @override
  void initState() {
    super.initState();
    final state = ref.read(libraryAutoSyncProvider);
    _dav = state.configured;
    _bangumi =
        (ref.read(secureStoreProvider).get('tracking.bangumi.token') ?? '')
            .isNotEmpty;
    final saved = ref
        .read(preferencesProvider)
        .get<String>('anime.follows.syncPriority');
    for (final priority in AnimeSyncPriority.values) {
      if (priority.name == saved) _priority = priority;
    }
  }

  Future<void> _start() async {
    if (_running || !_dav && !_bangumi) return;
    setState(() {
      _started = true;
      _running = true;
      _settingsError = null;
    });
    try {
      await ref
          .read(preferencesProvider)
          .set('anime.follows.syncPriority', _priority.name);
      if (!mounted || _cancelled) return;
      await ref
          .read(libraryAutoSyncProvider.notifier)
          .syncFollows(webDav: _dav, bangumi: _bangumi, priority: _priority);
    } catch (_) {
      if (mounted) setState(() => _settingsError = '同步设置未保存，请重试');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _cancel() {
    _cancelled = true;
    if (_running) ref.read(libraryAutoSyncProvider.notifier).cancelSync();
    Navigator.pop(context);
  }

  void _settings(String route) {
    Navigator.pop(context);
    context.push(route);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryAutoSyncProvider);
    final token = ref.read(secureStoreProvider).get('tracking.bangumi.token');
    final hasBangumi = token != null && token.isNotEmpty;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        scrollable: true,
        title: Text(_running ? '正在同步收藏' : '同步收藏'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('同步全部收藏分类。可独立选择服务；已完成的更改不会因其他步骤失败或取消而撤销。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('WebDAV 收藏'),
                subtitle: Text(
                  state.configured ? '复用收藏与历史同步连接' : '尚未配置 WebDAV',
                ),
                value: _dav,
                onChanged: _running || !state.configured
                    ? null
                    : (value) => setState(() => _dav = value!),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bangumi 状态'),
                subtitle: Text(
                  hasBangumi ? '使用已连接账号，不删除远端收藏' : '请先连接 Bangumi 追踪账号',
                ),
                value: _bangumi,
                onChanged: _running || !hasBangumi
                    ? null
                    : (value) => setState(() => _bangumi = value!),
              ),
              DropdownButtonFormField<AnimeSyncPriority>(
                initialValue: _priority,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Bangumi 状态冲突处理'),
                items: const [
                  DropdownMenuItem(
                    value: AnimeSyncPriority.local,
                    child: Text('本地优先'),
                  ),
                  DropdownMenuItem(
                    value: AnimeSyncPriority.bangumi,
                    child: Text('Bangumi 优先'),
                  ),
                  DropdownMenuItem(
                    value: AnimeSyncPriority.newest,
                    child: Text('最近修改优先'),
                  ),
                ],
                onChanged: _running
                    ? null
                    : (value) => setState(() => _priority = value!),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('冲突优先级仅决定 Bangumi 收藏状态；WebDAV 仍按各字段版本合并，不覆盖新进度。'),
              ),
              for (final stage in AnimeFollowSyncStage.values)
                _step(stage, _started ? state.stages[stage] : null),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动同步 Bangumi 收藏'),
                subtitle: const Text('启动、返回应用或收藏变化时同步；自动冲突按最近修改处理'),
                value: state.bangumiEnabled,
                onChanged: _running || !hasBangumi
                    ? null
                    : (value) async {
                        try {
                          await ref
                              .read(libraryAutoSyncProvider.notifier)
                              .setBangumiEnabled(value);
                        } catch (_) {
                          if (mounted) {
                            setState(() => _settingsError = '自动同步设置未保存，请重试');
                          }
                        }
                      },
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _running
                        ? null
                        : () => _settings(AppRoutes.webdav),
                    child: const Text('WebDAV 连接与历史'),
                  ),
                  TextButton(
                    onPressed: _running
                        ? null
                        : () => _settings('${AppRoutes.tracking}?type=anime'),
                    child: const Text('管理 Bangumi 账号'),
                  ),
                ],
              ),
              if (_settingsError != null)
                Text(
                  _settingsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _cancel,
            child: Text(
              _running
                  ? '取消同步'
                  : _started
                  ? '关闭'
                  : '取消',
            ),
          ),
          FilledButton.icon(
            onPressed: _running || !_dav && !_bangumi ? null : _start,
            icon: const Icon(Icons.sync),
            label: Text(_started ? '重新同步' : '开始同步'),
          ),
        ],
      ),
    );
  }

  Widget _step(AnimeFollowSyncStage stage, AnimeFollowSyncStep? step) {
    final (title, description, enabled) = switch (stage) {
      AnimeFollowSyncStage.webDav => (
        'WebDAV 收藏 · 第 1 步',
        '合并本地与云端收藏及历史',
        _dav,
      ),
      AnimeFollowSyncStage.bangumi => (
        'Bangumi 状态 · 第 2 步',
        '同步追番状态与已看进度',
        _bangumi,
      ),
      AnimeFollowSyncStage.upload => (
        '回传 WebDAV · 第 3 步',
        '上传合并后的收藏',
        _dav && _bangumi,
      ),
    };
    final phase = step?.phase;
    final label = switch (phase) {
      AnimeFollowSyncPhase.running => '正在同步…',
      AnimeFollowSyncPhase.succeeded => '已完成',
      AnimeFollowSyncPhase.failed => '失败',
      AnimeFollowSyncPhase.skipped => enabled ? '已跳过' : '未选择',
      AnimeFollowSyncPhase.cancelled => '已取消',
      _ => enabled ? description : '未选择',
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: phase == AnimeFollowSyncPhase.running
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(switch (phase) {
              AnimeFollowSyncPhase.succeeded => Icons.check_circle_outline,
              AnimeFollowSyncPhase.failed => Icons.error_outline,
              _ => Icons.sync,
            }),
      title: Text(title),
      subtitle: Text(
        step?.message == null ? label : '$label · ${step!.message}',
      ),
      textColor: phase == AnimeFollowSyncPhase.failed
          ? Theme.of(context).colorScheme.error
          : null,
    );
  }
}
