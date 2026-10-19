import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/source/mihon_source.dart';
import '../../core/source/windows_mihon_host.dart';
import '../../core/widgets/page_scaffold.dart';

Future<bool> openMihonPreferences(
  BuildContext context,
  MihonSource source,
) async {
  if (!source.enabled) throw StateError('此来源已停用；请先启用已信任的扩展');
  if (source.isConfigurable == false) throw StateError('此来源没有提供可配置设置');
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WindowsMihonSettingsPage(
          packageName: source.packageName,
          sourceId: source.hostSourceId,
          name: source.descriptor.name,
        ),
      ),
    );
    return true;
  }
  return source.openSettings();
}

/// Renders the real PreferenceScreen exported by the desktop compatibility host.
class WindowsMihonSettingsPage extends StatefulWidget {
  const WindowsMihonSettingsPage({
    super.key,
    required this.packageName,
    required this.sourceId,
    required this.name,
  });
  final String packageName, sourceId, name;

  @override
  State<WindowsMihonSettingsPage> createState() =>
      _WindowsMihonSettingsPageState();
}

class _WindowsMihonSettingsPageState extends State<WindowsMihonSettingsPage> {
  List<Map<String, Object?>>? _rows;
  Object? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await WindowsMihonHost.instance.preferences(
        widget.packageName,
        widget.sourceId,
      );
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save(int position, Object? value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await WindowsMihonHost.instance.setPreference(
        widget.packageName,
        widget.sourceId,
        position,
        value,
      );
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存来源设置失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editText(int index, Map<String, Object?> props) async {
    final controller = TextEditingController(
      text: '${props['currentValue'] ?? ''}',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${props['title'] ?? ''}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: RegExp(
            'password|token|secret',
            caseSensitive: false,
          ).hasMatch('${props['key']}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) await _save(index, value);
  }

  Future<void> _editMultiple(int index, Map<String, Object?> props) async {
    final entries = props['entries'] as List? ?? const [];
    final values = props['entryValues'] as List? ?? const [];
    final selected = <String>{
      for (final value in props['currentValue'] as List? ?? const []) '$value',
    };
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('${props['title'] ?? ''}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < values.length; i++)
                    CheckboxListTile(
                      title: Text(
                        '${i < entries.length ? entries[i] : values[i]}',
                      ),
                      value: selected.contains('${values[i]}'),
                      onChanged: (checked) => update(() {
                        if (checked == true) {
                          selected.add('${values[i]}');
                        } else {
                          selected.remove('${values[i]}');
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) await _save(index, result);
  }

  Widget _preference(int index, Map<String, Object?> row) {
    final props = Map<String, Object?>.from(row['props'] as Map);
    if (props['visible'] == false) return const SizedBox.shrink();
    final enabled = props['enabled'] != false && !_saving;
    final title = '${props['title'] ?? ''}';
    final summary = '${props['summary'] ?? ''}';
    switch (row['type']) {
      case 'SwitchPreferenceCompat':
      case 'CheckBoxPreference':
        return SwitchListTile(
          title: Text(title),
          subtitle: summary.isEmpty ? null : Text(summary),
          value: props['currentValue'] == true,
          onChanged: enabled ? (value) => _save(index, value) : null,
        );
      case 'ListPreference':
        final values = props['entryValues'] as List? ?? const [];
        final entries = props['entries'] as List? ?? const [];
        final current = '${props['currentValue'] ?? ''}';
        final selected = values.indexOf(current);
        return Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<String>(
            key: ValueKey('$index:$current'),
            initialValue: values.contains(current) ? current : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: title,
              helperText: summary.isEmpty
                  ? null
                  : summary.replaceAll(
                      '%s',
                      selected >= 0 && selected < entries.length
                          ? '${entries[selected]}'
                          : current,
                    ),
              helperMaxLines: 8,
            ),
            items: [
              for (var i = 0; i < values.length; i++)
                DropdownMenuItem(
                  value: '${values[i]}',
                  child: Text(
                    '${i < entries.length ? entries[i] : values[i]}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) _save(index, value);
                  }
                : null,
          ),
        );
      case 'EditTextPreference':
        return ListTile(
          title: Text(title),
          subtitle: summary.isEmpty ? null : Text(summary),
          trailing: const Icon(Icons.edit_outlined),
          enabled: enabled,
          onTap: () => _editText(index, props),
        );
      case 'MultiSelectListPreference':
        return ListTile(
          title: Text(title),
          subtitle: summary.isEmpty ? null : Text(summary),
          trailing: const Icon(Icons.checklist),
          enabled: enabled,
          onTap: () => _editMultiple(index, props),
        );
      default:
        return ListTile(
          title: Text(title),
          subtitle: Text(summary.isEmpty ? '此来源选项未提供可编辑类型' : summary),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${widget.name} · 来源设置')),
    body: _error != null
        ? EmptyStateView(
            icon: Icons.error_outline,
            title: '无法读取来源设置',
            message: '$_error',
            action: OutlinedButton(onPressed: _load, child: const Text('重试')),
          )
        : _rows == null
        ? const Center(child: CircularProgressIndicator())
        : _rows!.isEmpty
        ? const EmptyStateView(icon: Icons.tune, title: '此来源没有提供可配置设置')
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _rows!.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, index) => _preference(index, _rows![index]),
              ),
            ),
          ),
  );
}
