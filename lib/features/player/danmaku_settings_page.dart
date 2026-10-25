import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/text/zh_converter.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/danmaku_settings.dart';

class DanmakuSettingsPage extends StatelessWidget {
  const DanmakuSettingsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const PageScaffold(title: '弹幕设置', child: DanmakuSettingsPanel());
}

/// Reused in a bounded player sheet/side panel and the full settings page.
/// Requires the application's ProviderScope; changes publish immediately.
class DanmakuSettingsPanel extends ConsumerStatefulWidget {
  const DanmakuSettingsPanel({super.key, this.inPlayer = false});
  final bool inPlayer;

  @override
  ConsumerState<DanmakuSettingsPanel> createState() =>
      _DanmakuSettingsPanelState();
}

class _DanmakuSettingsPanelState extends ConsumerState<DanmakuSettingsPanel> {
  Future<void> _update(DanmakuSettings settings) async {
    try {
      await ref.read(danmakuSettingsProvider.notifier).update(settings);
    } catch (_) {
      if (mounted) _message('设置已应用，但保存失败，请重试');
    }
  }

  void _message(String message) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(danmakuSettingsProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        final sections = [
          _display(settings),
          _style(settings),
          _playback(settings),
          _shield(settings),
          _Section(
            title: '设置与来源',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restore),
                title: const Text('恢复默认显示设置'),
                subtitle: const Text('保留全部屏蔽规则、屏蔽用户和来源匹配'),
                onTap: _reset,
              ),
              const Text(
                '来源匹配、分集纠正和时间偏移在播放器「弹幕来源」中调整。'
                '来源是否有弹幕取决于该站点的内容覆盖与网络可用性，当前提供只读弹幕。',
              ),
            ],
          ),
        ];
        return ListView(
          key: PageStorageKey('danmaku-settings-${widget.inPlayer}'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (widget.inPlayer)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '弹幕设置 · 即时生效',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            if (wide)
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final section in sections)
                    SizedBox(
                      width: (constraints.maxWidth - 48) / 2,
                      child: section,
                    ),
                ],
              )
            else
              for (final section in sections)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: section,
                ),
          ],
        );
      },
    );
  }

  Widget _display(DanmakuSettings s) => _Section(
    title: '显示',
    children: [
      _switch('显示弹幕', s.enabled, (v) => s.copyWith(enabled: v)),
      _slider(
        '显示区域',
        s.area,
        0,
        1,
        8,
        '${(s.area * 100).round()}%',
        (v) => s.copyWith(area: v),
      ),
      _slider(
        '不透明度',
        s.opacity,
        0.1,
        1,
        90,
        '${(s.opacity * 100).round()}%',
        (v) => s.copyWith(opacity: v),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip('滚动', s.showScroll, (v) => s.copyWith(showScroll: v)),
          _chip('顶部', s.showTop, (v) => s.copyWith(showTop: v)),
          _chip('底部', s.showBottom, (v) => s.copyWith(showBottom: v)),
        ],
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<ZhConversionMode>(
        key: ValueKey(s.conversion),
        initialValue: s.conversion,
        decoration: const InputDecoration(labelText: '简繁转换'),
        items: const [
          DropdownMenuItem(value: ZhConversionMode.off, child: Text('不转换')),
          DropdownMenuItem(value: ZhConversionMode.t2s, child: Text('转为简体')),
          DropdownMenuItem(value: ZhConversionMode.s2t, child: Text('转为繁体')),
        ],
        onChanged: (value) {
          if (value != null) unawaited(_update(s.copyWith(conversion: value)));
        },
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('复用本地 OpenCC 单字字表，即时转换；多义字可能存在差异。'),
      ),
    ],
  );

  Widget _style(DanmakuSettings s) => _Section(
    title: '样式',
    children: [
      _slider(
        '字体大小',
        s.fontSize,
        10,
        48,
        38,
        '${s.fontSize.round()}',
        (v) => s.copyWith(fontSize: v),
      ),
      _slider(
        '字体字重',
        s.fontWeight.toDouble(),
        1,
        9,
        8,
        '${s.fontWeight}',
        (v) => s.copyWith(fontWeight: v.round()),
      ),
      _slider(
        '弹幕行高',
        s.lineHeight,
        0,
        3,
        30,
        s.lineHeight.toStringAsFixed(1),
        (v) => s.copyWith(lineHeight: v),
        description: '小行高仍保留字形所需高度，避免航道相互遮挡。',
      ),
      _switch(
        '弹幕颜色',
        s.showColor,
        (v) => s.copyWith(showColor: v),
        subtitle: '关闭后统一显示白色',
      ),
      _switch('弹幕描边', s.outline, (v) => s.copyWith(outline: v)),
      _slider(
        '描边粗细',
        s.outlineWidth,
        0.1,
        3,
        29,
        s.outlineWidth.toStringAsFixed(1),
        (v) => s.copyWith(outlineWidth: v),
        enabled: s.outline,
      ),
    ],
  );

  Widget _playback(DanmakuSettings s) => _Section(
    title: '播放与密度',
    children: [
      _slider(
        '持续时间',
        s.durationSeconds,
        2,
        16,
        14,
        '${s.durationSeconds.round()} 秒',
        (v) => s.copyWith(durationSeconds: v),
      ),
      _switch(
        '跟随视频倍速',
        s.followVideoRate,
        (v) => s.copyWith(followVideoRate: v),
        subtitle: '仅改变移动与停留速度，弹幕入场仍对齐视频时间轴',
      ),
      _switch(
        '海量弹幕',
        s.massive,
        (v) => s.copyWith(massive: v),
        subtitle: s.massive ? '允许同航道叠加，仍限制屏幕上的弹幕数量' : '检测航道碰撞，拥挤时跳过弹幕',
      ),
      _slider(
        '屏幕弹幕上限',
        s.maxActive.toDouble(),
        20,
        300,
        28,
        '${s.maxActive} 条',
        (v) => s.copyWith(maxActive: v.round()),
      ),
      _switch(
        '合并重复弹幕',
        s.mergeDuplicates,
        (v) => s.copyWith(mergeDuplicates: v),
        subtitle: '同类型、同文字的弹幕在 5 秒内只显示一条',
      ),
    ],
  );

  Widget _shield(DanmakuSettings s) => _Section(
    title: '屏蔽规则',
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: _editRule,
            icon: const Icon(Icons.add),
            label: const Text('添加规则'),
          ),
          OutlinedButton.icon(
            onPressed: _importRules,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('导入'),
          ),
          OutlinedButton.icon(
            onPressed: _exportRules,
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('导出'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        '支持关键词或 /正则/。安全正则支持字符类、锚点和一个可变重复项；'
        '不支持分组、择一、环视或反向引用。每条最多 128 字，最多 256 条。',
      ),
      if (s.blockedWords.isEmpty && s.shieldRules.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('还没有屏蔽规则'),
        ),
      for (var index = 0; index < s.blockedWords.length; index++)
        _ruleTile(
          DanmakuShieldRule(text: s.blockedWords[index]),
          legacyIndex: index,
        ),
      for (var index = 0; index < s.shieldRules.length; index++)
        _ruleTile(s.shieldRules[index], index: index),
      if (s.blockedUsers.isNotEmpty) ...[
        const Divider(),
        Text('已屏蔽用户 · ${s.blockedUsers.length}'),
        for (final user in s.blockedUsers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(user, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              tooltip: '取消屏蔽用户',
              icon: const Icon(Icons.close),
              onPressed: () {
                final current = ref.read(danmakuSettingsProvider);
                unawaited(
                  _update(
                    current.copyWith(
                      blockedUsers: [
                        for (final item in current.blockedUsers)
                          if (item != user) item,
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ],
  );

  Widget _ruleTile(
    DanmakuShieldRule rule, {
    int? index,
    int? legacyIndex,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Switch(
      value: rule.enabled,
      onChanged: rule.validationError != null
          ? null
          : (enabled) {
              final current = ref.read(danmakuSettingsProvider);
              if (legacyIndex != null) {
                if (current.shieldRules.length >= DanmakuShieldRule.maxRules) {
                  _message('屏蔽规则已满，请先删除一条规则再切换旧屏蔽词');
                  return;
                }
                unawaited(
                  _update(
                    current.copyWith(
                      blockedWords: [...current.blockedWords]
                        ..removeAt(legacyIndex),
                      shieldRules: [
                        ...current.shieldRules,
                        rule.copyWith(enabled: enabled),
                      ],
                    ),
                  ),
                );
              } else {
                final rules = [...current.shieldRules];
                rules[index!] = rule.copyWith(enabled: enabled);
                unawaited(_update(current.copyWith(shieldRules: rules)));
              }
            },
    ),
    title: Text(rule.text, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(rule.validationError ?? (rule.isRegex ? '正则表达式' : '关键词')),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '编辑规则',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () =>
              _editRule(rule: rule, index: index, legacyIndex: legacyIndex),
        ),
        IconButton(
          tooltip: '删除规则',
          icon: const Icon(Icons.close),
          onPressed: () {
            final current = ref.read(danmakuSettingsProvider);
            unawaited(
              _update(
                legacyIndex != null
                    ? current.copyWith(
                        blockedWords: [...current.blockedWords]
                          ..removeAt(legacyIndex),
                      )
                    : current.copyWith(
                        shieldRules: [...current.shieldRules]..removeAt(index!),
                      ),
              ),
            );
          },
        ),
      ],
    ),
  );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    String valueLabel,
    DanmakuSettings Function(double) next, {
    String? description,
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label $valueLabel'),
        if (description != null)
          Text(description, style: Theme.of(context).textTheme.bodySmall),
        Slider(
          key: ValueKey(label),
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: enabled ? (v) => unawaited(_update(next(v))) : null,
        ),
      ],
    ),
  );

  Widget _switch(
    String title,
    bool value,
    DanmakuSettings Function(bool) next, {
    String? subtitle,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: (v) => unawaited(_update(next(v))),
  );

  Widget _chip(
    String title,
    bool selected,
    DanmakuSettings Function(bool) next,
  ) => FilterChip(
    label: Text(title),
    selected: selected,
    onSelected: (v) => unawaited(_update(next(v))),
  );

  Future<void> _editRule({
    DanmakuShieldRule? rule,
    int? index,
    int? legacyIndex,
  }) async {
    final result = await showDialog<DanmakuShieldRule>(
      context: context,
      builder: (_) => _RuleDialog(rule: rule),
    );
    if (result == null || !mounted) return;
    final current = ref.read(danmakuSettingsProvider);
    final rules = [...current.shieldRules];
    if (index != null) {
      rules[index] = result;
    } else {
      if (rules.length >= DanmakuShieldRule.maxRules) {
        _message('最多保存 256 条屏蔽规则');
        return;
      }
      if (rules.any(
        (r) => r.text == result.text && r.isRegex == result.isRegex,
      )) {
        return;
      }
      rules.add(result);
    }
    await _update(
      current.copyWith(
        shieldRules: rules,
        blockedWords: legacyIndex == null
            ? null
            : ([...current.blockedWords]..removeAt(legacyIndex)),
      ),
    );
  }

  Future<void> _importRules() async {
    final input = await showDialog<String>(
      context: context,
      builder: (_) => const _ImportDialog(),
    );
    if (input == null || !mounted) return;
    try {
      final current = ref.read(danmakuSettingsProvider);
      await _update(current.importShieldRules(input));
      if (mounted) _message('已合并导入屏蔽规则');
    } on FormatException catch (error) {
      _message('导入失败：${error.message}');
    }
  }

  Future<void> _exportRules() async {
    final text = ref.read(danmakuSettingsProvider).exportShieldRules();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出屏蔽规则'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) _message('已复制屏蔽规则');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认弹幕设置？'),
        content: const Text('显示和播放设置恢复为默认值；所有屏蔽规则和屏蔽用户保持不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _update(ref.read(danmakuSettingsProvider).restoreDefaults());
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        ...children,
      ],
    ),
  );
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.rule});
  final DanmakuShieldRule? rule;
  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final TextEditingController _text;
  late bool _regex;
  String? _error;
  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.rule?.text ?? '');
    _regex = widget.rule?.isRegex ?? false;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final rule = DanmakuShieldRule(
      text: _text.text.trim(),
      isRegex: _regex,
      enabled: widget.rule?.enabled ?? true,
    );
    final error = rule.validationError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.rule == null ? '添加屏蔽规则' : '编辑屏蔽规则'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: DanmakuShieldRule.maxLength,
            decoration: InputDecoration(
              labelText: _regex ? '正则表达式（无需斜杠）' : '屏蔽关键词',
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('正则表达式'),
            value: _regex,
            onChanged: (value) => setState(() {
              _regex = value;
              _error = null;
            }),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导入屏蔽规则'),
    content: SizedBox(
      width: 520,
      child: TextField(
        controller: _text,
        minLines: 4,
        maxLines: 10,
        maxLength: 128 * 1024,
        decoration: const InputDecoration(hintText: '粘贴导出的 JSON，或每行一个关键词 /正则/'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: const Text('合并导入'),
      ),
    ],
  );
}
