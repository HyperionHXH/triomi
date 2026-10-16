import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database_provider.dart';
import '../../core/source/source_providers.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/library_providers.dart';
import 'data/source_migration_repository.dart';

final migrationPlansProvider = StreamProvider(
  (ref) => SourceMigrationRepository(ref.watch(databaseProvider)).watchPlans(),
);

class MigrationPlansPage extends ConsumerStatefulWidget {
  const MigrationPlansPage({super.key});
  @override
  ConsumerState<MigrationPlansPage> createState() => _MigrationPlansPageState();
}

class _MigrationPlansPageState extends ConsumerState<MigrationPlansPage> {
  final _selected = <String>{};
  bool _running = false;
  String? _error;
  Future<void> _execute(Set<String> ids) async {
    if (_running) return;
    setState(() => _running = true);
    final repo = SourceMigrationRepository(ref.read(databaseProvider));
    try {
      final plans = await ref.read(migrationPlansProvider.future);
      for (final id in ids) {
        final plan = plans.firstWhere((p) => p.id == id);
        final payload = jsonDecode(plan.payload) as Map;
        final source = (payload['target'] as Map)['sourceId'];
        final latest = await ref.read(sourceRegistryProvider).load();
        if (!latest.enabledEntries.any((e) => e.descriptor.id == source)) {
          _error = '目标来源已停用，未执行计划';
          continue;
        }
        try {
          await repo.executeMigration(id);
        } catch (_) {
          _error = '部分计划失败，原数据保留；查看单项错误';
        }
      }
      ref.invalidate(libraryByTypeProvider);
      ref.invalidate(historyProvider);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '持久迁移计划',
    child: Column(
      children: [
        FilledButton(
          onPressed: _running || _selected.isEmpty
              ? null
              : () => _execute({..._selected}),
          child: Text(_running ? '执行中' : '执行所选 ${_selected.length} 项'),
        ),
        if (_error != null) Text(_error!),
        Expanded(
          child: ref
              .watch(migrationPlansProvider)
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => const Text('计划读取失败'),
                data: (plans) => ListView(
                  children: [
                    if (plans.isEmpty)
                      const ListTile(
                        title: Text('没有已保存计划'),
                        subtitle: Text('在作品复制页预览范围后保存，可独立重启后恢复执行'),
                      ),
                    for (final plan in plans)
                      Builder(
                        builder: (context) {
                          final payload = jsonDecode(plan.payload) as Map;
                          final origin = payload['origin'] as Map,
                              target = payload['target'] as Map;
                          return CheckboxListTile(
                            value: _selected.contains(plan.id),
                            onChanged: plan.status == 'completed' || _running
                                ? null
                                : (v) => setState(
                                    () => v == true
                                        ? _selected.add(plan.id)
                                        : _selected.remove(plan.id),
                                  ),
                            title: Text(
                              '${origin['title']} → ${target['title']}',
                            ),
                            subtitle: Text(
                              '${target['sourceId']}\n${plan.status}${plan.error == null ? '' : '\n${plan.error}'}\n已选范围：${payload['scope']}\n明确映射 ${(payload['mappings'] as Map).length} 章；旧版离线文件 ${(payload['files'] as List).length} 章',
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
        ),
      ],
    ),
  );
}
