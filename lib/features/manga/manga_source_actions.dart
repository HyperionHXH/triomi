import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/source_website.dart';
import '../../core/source/windows_source_session.dart';
import '../sources/sources_page.dart';
import 'windows_mihon_settings_page.dart';

enum MangaSourceAction { settings, browser, session }

String mangaSourceSettingsLabel(SourceEntry entry) =>
    entry.source is MihonSource ? '插件来源设置' : '规则与来源设置';

bool mangaSourceSupportsSession(SourceEntry entry) =>
    !(entry.source is MihonSource &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows);

Future<void> performMangaSourceAction(
  BuildContext context,
  SourceEntry entry,
  MangaSourceAction action,
) async {
  void message(String text) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  try {
    final source = entry.source;
    if (action == MangaSourceAction.settings && source is! MihonSource) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => const SourcesPage(initialType: MediaType.manga),
        ),
      );
      return;
    }
    if (!entry.enabled || source is MihonSource && !source.enabled) {
      message('此来源已停用；请先在来源或扩展管理中启用已信任的来源');
      return;
    }
    if (action == MangaSourceAction.settings) {
      final opened = await openMihonPreferences(context, source as MihonSource);
      if (!opened) message('当前宿主无法打开此来源设置');
      return;
    }
    if (action == MangaSourceAction.session && source is MihonSource) {
      if (!mangaSourceSupportsSession(entry)) {
        message('桌面插件使用独立兼容运行时；网站登录请使用插件提供的来源设置，网页会话不冒充已同步');
        return;
      }
      final saved = await source.openWebSession();
      if (saved) message('应用内站点会话已保存；不与外部浏览器共享，不代表验证已通过');
      return;
    }
    final uri = source is MihonSource
        ? await source.websiteUri()
        : publicSourceWebsiteUri(entry.descriptor.baseUrl ?? '');
    if (action == MangaSourceAction.browser) {
      final opened = await platformChannel.launchExternalUrl(uri.toString());
      if (!opened) message('无法打开外部浏览器：当前平台不支持或没有可用浏览器');
    } else {
      final bool saved;
      if (source is KazumiSource) {
        saved = await source.openWebSession(url: uri.toString());
      } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        saved = await WindowsSourceSession.open(
          sourceId: entry.descriptor.id,
          url: uri.toString(),
          userAgent: 'Mozilla/5.0',
        );
      } else {
        saved = await platformChannel.openRuleSession(
          uri.toString(),
          'Mozilla/5.0',
        );
      }
      if (saved) message('应用内站点会话已保存；不与外部浏览器共享，不代表验证已通过');
    }
  } on PlatformException catch (error) {
    message(SourceException.sanitizeMessage(error.message ?? error.code));
  } on Object catch (error) {
    message('无法打开来源功能：${SourceException.sanitizeMessage('$error')}');
  }
}

Future<MangaSourceAction?> showMangaSourceActionMenu(
  BuildContext context,
  SourceEntry entry, {
  VoidCallback? onExtensionDetails,
}) => showModalBottomSheet<MangaSourceAction>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheetContext) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(entry.descriptor.name),
            subtitle: Text(entry.enabled ? '已启用' : '已停用；启用后可执行插件设置与会话'),
          ),
          if (onExtensionDetails != null)
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('插件详情与来源设置'),
              onTap: () {
                Navigator.pop(sheetContext);
                onExtensionDetails();
              },
            ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(mangaSourceSettingsLabel(entry)),
            onTap: () =>
                Navigator.pop(sheetContext, MangaSourceAction.settings),
          ),
          if (entry.source is MihonSource ||
              entry.descriptor.baseUrl != null) ...[
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: const Text('在外部浏览器打开'),
              subtitle: const Text('不传递应用内 Cookie 或认证请求头'),
              onTap: () =>
                  Navigator.pop(sheetContext, MangaSourceAction.browser),
            ),
            if (mangaSourceSupportsSession(entry))
              ListTile(
                leading: const Icon(Icons.language),
                title: const Text('应用内网页 / 会话验证'),
                subtitle: const Text('使用此来源的应用内会话，与外部浏览器分开'),
                onTap: () =>
                    Navigator.pop(sheetContext, MangaSourceAction.session),
              ),
          ],
        ],
      ),
    ),
  ),
);
