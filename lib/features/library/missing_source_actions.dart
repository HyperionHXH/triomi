import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../detail/anime_source_sheet.dart';
import '../manga/manga_extensions_page.dart';
import '../profile/data/synced_source_hint.dart';
import '../sources/sources_page.dart';
import 'source_migration_page.dart';

enum _SourceState { disabled, missing, unavailable }

class _MissingSourceInfo {
  const _MissingSourceInfo({
    required this.sourceId,
    required this.name,
    required this.state,
    this.packageName,
    this.repoUrl,
  });

  final String sourceId;
  final String name;
  final String? packageName;
  final String? repoUrl;
  final _SourceState state;

  String get title => switch (state) {
    _SourceState.disabled => '来源已停用',
    _SourceState.missing => '此设备缺少原来源',
    _SourceState.unavailable => '已安装的来源当前不可用',
  };

  String get message {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        sourceId.startsWith('mihon:')) {
      return 'iOS 不执行 Mihon APK/DEX；如果备份中保留了扩展文件，也不能在这里启用。'
          '请从应用内 JS/API 来源目录安装兼容规则，或搜索其他来源；不会安装外部应用。';
    }
    return switch (state) {
      _SourceState.disabled => '原来源已安装或保留在本机，但当前停用。请到来源管理中核对后手动启用，或选择其他来源。',
      _SourceState.missing => '此设备没有原插件或来源。可在插件库中核对并安装，或搜索其他来源后确认迁移。',
      _SourceState.unavailable => '已找到插件安装记录，但没有可用的准确来源身份。请检查插件状态，或选择其他来源。',
    };
  }
}

String? _safeRepositoryHint(String? value) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      value.contains(RegExp(r'[\x00-\x20\\]'))) {
    return '记录的仓库地址格式不安全或不完整，请在插件库中自行核对';
  }
  return uri.toString();
}

/// Only reads saved source rows and APK metadata; never initializes a plugin.
Future<_MissingSourceInfo?> _missingSourceInfo(
  WidgetRef ref,
  MediaItem item,
) async {
  if (item.type == MediaType.novel || item.sourceId == 'local-comic') {
    return null;
  }
  final db = ref.read(databaseProvider);
  final hint = await readSyncedSourceHint(db, item);
  final row = await (db.select(
    db.sources,
  )..where((source) => source.id.equals(item.sourceId))).getSingleOrNull();
  final parts = item.sourceId.split(':');
  if (parts.length >= 3 && parts.first == 'mihon') {
    // Availability is keyed by the actual item identity, never by remote hints.
    final package = parts[1];
    final hostSource = parts.sublist(2).join(':');
    final preferences = ref.read(preferencesProvider);
    final installed = preferences.get<Map<dynamic, dynamic>>(
      'mihon.installedPackages',
    );
    final statuses = preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus');
    final rawStatus = statuses?[package];
    final status = rawStatus is Map ? rawStatus : const <Object?, Object?>{};
    final rawSources = status['sources'];
    Map<Object?, Object?>? exactSource;
    if (rawSources is List) {
      for (final candidate in rawSources) {
        if (candidate is Map && '${candidate['id'] ?? ''}' == hostSource) {
          exactSource = candidate;
          break;
        }
      }
    }
    final packageInstalled =
        installed?.containsKey(package) == true || rawStatus is Map;
    final enabled =
        (preferences.get<List<Object?>>('mihon.enabledPackages') ?? const [])
            .any((value) => '$value' == package);
    if (packageInstalled &&
        enabled &&
        status['ok'] == true &&
        exactSource != null) {
      return null;
    }
    final localName = '${exactSource?['name'] ?? status['name'] ?? ''}'.trim();
    return _MissingSourceInfo(
      sourceId: item.sourceId,
      name: localName.isNotEmpty
          ? localName
          : hint?.name ?? row?.name ?? package,
      packageName: package,
      repoUrl: _safeRepositoryHint(hint?.repoUrl ?? row?.repoUrl),
      state: !packageInstalled
          ? _SourceState.missing
          : !enabled
          ? _SourceState.disabled
          : _SourceState.unavailable,
    );
  }
  // Bangumi public metadata is built into the app's detail flow.
  if (item.sourceId == 'bangumi-anime') return null;
  if (row != null && row.type == item.type && row.enabled) return null;
  return _MissingSourceInfo(
    sourceId: item.sourceId,
    name: row?.name ?? hint?.name ?? item.sourceId,
    packageName: hint?.packageName,
    repoUrl: _safeRepositoryHint(hint?.repoUrl ?? row?.repoUrl),
    state: row == null
        ? _SourceState.missing
        : !row.enabled
        ? _SourceState.disabled
        : _SourceState.unavailable,
  );
}

/// Adds recovery actions to detail without delaying normal navigation.
class MissingSourceNotice extends ConsumerStatefulWidget {
  const MissingSourceNotice({
    super.key,
    required this.item,
    this.onSourceChanged,
  });

  final MediaItem item;
  final VoidCallback? onSourceChanged;

  @override
  ConsumerState<MissingSourceNotice> createState() =>
      _MissingSourceNoticeState();
}

class _MissingSourceNoticeState extends ConsumerState<MissingSourceNotice> {
  late Future<_MissingSourceInfo?> _future;

  @override
  void initState() {
    super.initState();
    _future = _missingSourceInfo(ref, widget.item);
  }

  @override
  void didUpdateWidget(MissingSourceNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.remoteId != widget.item.remoteId) {
      _future = _missingSourceInfo(ref, widget.item);
    }
  }

  Future<void> _open() async {
    final changed = await showMissingSourceAction(context, ref, widget.item);
    if (!mounted) return;
    setState(() {
      _future = _missingSourceInfo(ref, widget.item);
    });
    if (changed) widget.onSourceChanged?.call();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_MissingSourceInfo?>(
    future: _future,
    builder: (context, snapshot) {
      final info = snapshot.data;
      if (info == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.extension_off_outlined),
                title: Text(info.title),
                subtitle: Text('${info.name}\n${info.message}'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: OutlinedButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.build_outlined),
                  label: const Text('安装 / 管理来源或搜索迁移'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Returns true when the user chooses a recovery action. Hints are display-only.
Future<bool> showMissingSourceAction(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  final info = await _missingSourceInfo(ref, item);
  if (!context.mounted || info == null) return false;
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(info.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(info.name),
            const SizedBox(height: 8),
            Text(info.message),
            const SizedBox(height: 12),
            const Text('精确来源 ID'),
            SelectableText(info.sourceId),
            if (info.packageName case final package?) ...[
              const SizedBox(height: 8),
              const Text('插件包名'),
              SelectableText(package),
            ],
            if (info.repoUrl case final repository?) ...[
              const SizedBox(height: 8),
              const Text('仓库提示（仅供核对）'),
              SelectableText(repository),
            ],
            const SizedBox(height: 12),
            const Text(
              '同步记录不会自动添加仓库、安装或信任插件，也不会自动启用来源。选择其他来源时请核对作品；原站页码和播放秒数不能直接沿用。',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'manage'),
          child: Text(
            info.sourceId.startsWith('mihon:') &&
                    !kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.iOS
                ? '打开 JS / API 来源目录'
                : info.sourceId.startsWith('mihon:')
                ? '打开插件库 / 管理'
                : '打开来源管理 / 插件库',
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, 'migrate'),
          child: Text(item.type == MediaType.anime ? '搜索其他播放站' : '搜索其他来源并迁移'),
        ),
      ],
    ),
  );
  if (!context.mounted || action == null) return false;
  if (action == 'manage') {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            info.sourceId.startsWith('mihon:') &&
                (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS)
            ? MangaExtensionsPage(initialQuery: info.packageName ?? info.name)
            : SourcesPage(
                initialType: item.type,
                initialQuery: info.sourceId.startsWith('mihon:')
                    ? null
                    : info.name,
              ),
      ),
    );
    if (!context.mounted) return true;
    ref.invalidate(sourceRegistryProvider);
    ref.invalidate(sourcesProvider);
    return true;
  }
  if (item.type == MediaType.anime) {
    final selected = await showAnimeSources(context, item);
    if (selected != null && context.mounted) {
      context.pushReplacement(AppRoutes.detailFor(selected), extra: selected);
    }
    return selected != null;
  }
  final target = await Navigator.of(context).push<MediaItem>(
    MaterialPageRoute<MediaItem>(
      builder: (_) => SourceMigrationPage(item: item),
    ),
  );
  if (target != null && context.mounted) {
    unawaited(context.push(AppRoutes.detailFor(target), extra: target));
  }
  return target != null;
}
