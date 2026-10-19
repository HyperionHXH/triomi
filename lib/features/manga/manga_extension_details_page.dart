import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/mihon_source.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import 'manga_source_actions.dart';

/// An APK can contain many independently configurable sources. Package metadata
/// is informational; every settings/browser action uses the real source host.
class MangaExtensionDetailsPage extends ConsumerWidget {
  const MangaExtensionDetailsPage({super.key, required this.packageName});
  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(preferencesProvider);
    final raw = preferences.get<Map<dynamic, dynamic>>(
      'mihon.hostStatus',
    )?[packageName];
    final host = raw is Map ? raw : const <Object?, Object?>{};
    final enabled =
        host['ok'] == true &&
        (preferences.get<List<Object?>>('mihon.enabledPackages') ?? [])
            .contains(packageName);
    return Scaffold(
      appBar: AppBar(title: const Text('插件详情与来源设置')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: SelectableText(packageName),
            subtitle: Text(
              'v${host['versionName'] ?? host['versionCode'] ?? '未知'} · ${enabled ? '已启用' : '未启用 / 宿主不可用'}',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SelectableText(
              '发布者指纹：${host['signerSha256'] ?? '没有已验证的发布者记录'}',
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '来源设置由插件自身提供并保存在本机，执行请求时使用同一份设置。一个插件可包含多个来源，请分别设置。外部浏览器不共享应用内会话。',
            ),
          ),
          ref
              .watch(sourcesProvider)
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('无法读取插件来源：$error'),
                ),
                data: (snapshot) {
                  final entries = snapshot.entries
                      .where(
                        (entry) =>
                            entry.source is MihonSource &&
                            (entry.source as MihonSource).packageName ==
                                packageName,
                      )
                      .toList();
                  if (entries.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '${host['hostError'] ?? host['error'] ?? '当前没有可执行的插件来源。Mihon APK 仅由支持的 Android 宿主加载；未信任、待恢复或宿主不可用时不会执行插件设置。'}',
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final entry in entries)
                        _SourceSettingsTile(entry: entry),
                    ],
                  );
                },
              ),
        ],
      ),
    );
  }
}

class _SourceSettingsTile extends StatelessWidget {
  const _SourceSettingsTile({required this.entry});
  final SourceEntry entry;
  @override
  Widget build(BuildContext context) {
    final source = entry.source as MihonSource;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.descriptor.name} · ${entry.descriptor.lang}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              !entry.enabled
                  ? '来源已停用，请先启用已信任的插件'
                  : source.isConfigurable == false
                  ? '此来源没有提供可配置设置'
                  : '使用插件提供的来源偏好设置',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('来源设置'),
                  onPressed: () => performMangaSourceAction(
                    context,
                    entry,
                    MangaSourceAction.settings,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('外部浏览器'),
                  onPressed: () => performMangaSourceAction(
                    context,
                    entry,
                    MangaSourceAction.browser,
                  ),
                ),
                if (mangaSourceSupportsSession(entry))
                  TextButton.icon(
                    icon: const Icon(Icons.language),
                    label: const Text('应用内网页 / 会话验证'),
                    onPressed: () => performMangaSourceAction(
                      context,
                      entry,
                      MangaSourceAction.session,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
