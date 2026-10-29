import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/catalog_repository.dart';

/// Scrollable at large text sizes; changing repositories never removes rules.
class CatalogRepositoriesSheet extends ConsumerStatefulWidget {
  const CatalogRepositoriesSheet({super.key});

  @override
  ConsumerState<CatalogRepositoriesSheet> createState() =>
      _CatalogRepositoriesSheetState();
}

class _CatalogRepositoriesSheetState
    extends ConsumerState<CatalogRepositoriesSheet> {
  final _url = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _change(Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repositories = ref.watch(catalogRepositoriesProvider);
    final controller = ref.read(catalogRepositoriesProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          // iOS can report a transient keyboard frame outside the view.
          16 + math.max(0.0, MediaQuery.viewInsetsOf(context).bottom),
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '管理兼容仓库',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭仓库管理',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Text('1. 添加可信的 HTTPS 仓库索引\n2. 返回目录浏览规则\n3. 确认仓库后安装或更新'),
                const SizedBox(height: 8),
                const Text(
                  '仅支持 JS / API 规则；不会转换或执行 APK。浏览不执行规则。停用或移除仓库不会卸载已安装来源，也不会删除书架、历史或下载。',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('catalog-repository-url'),
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '仓库索引 HTTPS 地址',
                    helperText: '支持直接兼容索引，或含 triomi.indexUrl 的 Android 仓库索引',
                    helperMaxLines: 4,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const ValueKey('catalog-repository-add'),
                    onPressed: _saving
                        ? null
                        : () => _change(() async {
                            await controller.add(_url.text);
                            _url.clear();
                          }),
                    icon: const Icon(Icons.add),
                    label: const Text('添加仓库'),
                  ),
                ),
                if (!repositories.any(
                  (repository) =>
                      repository.url ==
                      CatalogRepositoriesController.officialUrl,
                ))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      key: const ValueKey('catalog-repository-official'),
                      onPressed: _saving
                          ? null
                          : () => _change(
                              () => controller.add(
                                CatalogRepositoriesController.officialUrl,
                              ),
                            ),
                      child: const Text('添加官方兼容仓库'),
                    ),
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Divider(),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('内置离线目录'),
                  subtitle: Text('随应用提供 · 始终可用 · 不依赖远程仓库'),
                  leading: Icon(Icons.inventory_2_outlined),
                ),
                for (final repository in repositories)
                  Card(
                    key: ValueKey('repository:${repository.id}'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            repository.label,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          SelectableText(repository.url),
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(repository.enabled ? '已启用' : '已停用'),
                              Switch(
                                key: ValueKey(
                                  'repository-enabled:${repository.id}',
                                ),
                                value: repository.enabled,
                                onChanged: _saving
                                    ? null
                                    : (enabled) => _change(
                                        () => controller.setEnabled(
                                          repository.id,
                                          enabled: enabled,
                                        ),
                                      ),
                              ),
                              TextButton.icon(
                                onPressed: _saving
                                    ? null
                                    : () => _change(
                                        () => controller.remove(repository.id),
                                      ),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('移除仓库'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
