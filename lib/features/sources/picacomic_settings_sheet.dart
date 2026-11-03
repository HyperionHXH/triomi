import 'package:flutter/material.dart';

import '../../core/source/picacomic/picacomic_js_source.dart';

Future<void> showPicacomicSettingsSheet(
  BuildContext context,
  PicacomicJsSource source,
) async {
  final blocked = TextEditingController(text: source.settings.blocked);
  var quality = source.settings.quality;
  var sort = source.settings.sort;
  var busy = false;
  String? error;
  try {
    final route = DialogRoute<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: const Text('哔咔漫画 · 来源设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('需要源站账号。账号、密码和会话仅保存在系统安全存储，用于登录及会话续期，不提供注册或权限绕过。'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: quality,
                decoration: const InputDecoration(labelText: '图片质量'),
                items: [
                  for (final entry in const {
                    'original': '原图',
                    'low': '低',
                    'medium': '中',
                    'high': '高',
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => quality = value!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: sort,
                decoration: const InputDecoration(labelText: '列表与搜索排序'),
                items: [
                  for (final entry in const {
                    'dd': '新到旧',
                    'da': '旧到新',
                    'ld': '最多爱心',
                    'vd': '最多浏览',
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => sort = value!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: blocked,
                enabled: !busy,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '屏蔽分类 / 标签',
                  helperText: '用逗号分隔；仅过滤当前返回列表，可能出现空页',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '使用官方 HTTPS API 和系统 DNS（分流 1）。不使用 Android 插件的明文分流地址或跳过 TLS 校验。源站收藏只读，不自动同步增删。',
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await source.updateSetting('quality', quality);
                        await source.updateSetting('sort', sort);
                        await source.updateSetting('blocked', blocked.text);
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (context.mounted) {
                          setState(() {
                            busy = false;
                            error = '保存失败，请重试';
                          });
                        }
                      }
                    },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    // Pop returns before the exit animation removes the TextField.
    await route.completed;
  } finally {
    blocked.dispose();
  }
}
