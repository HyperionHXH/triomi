import 'package:flutter/material.dart';

import 'danmaku_episode_picker.dart';
import 'data/danmaku_session.dart';
import 'data/hybrid_danmaku_models.dart';

/// Bounded and independently scrollable on phones, short landscape and desktop.
class DanmakuSourcesPanel extends StatefulWidget {
  const DanmakuSourcesPanel({
    super.key,
    required this.session,
    required this.onEnabledChanged,
    required this.onAssociate,
  });
  final DanmakuSession session;
  final Future<void> Function(bool) onEnabledChanged;
  final VoidCallback onAssociate;

  @override
  State<DanmakuSourcesPanel> createState() => _DanmakuSourcesPanelState();
}

class _DanmakuSourcesPanelState extends State<DanmakuSourcesPanel> {
  final _reference = TextEditingController();
  final _gamerReference = TextEditingController();
  String? _inputError;

  @override
  void dispose() {
    _reference.dispose();
    _gamerReference.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _inputError = null);
    } catch (error) {
      if (mounted) {
        setState(
          () => _inputError = error is FormatException
              ? error.message
              : '设置未能保存，请重试',
        );
      }
    }
  }

  Future<void> _offset(DanmakuProviderKind kind) async {
    final bindingKey = widget.session.bindingKey;
    var input = widget.session.source(kind).offsetSeconds.toString();
    String? error;
    final value = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void submit() {
            final value = double.tryParse(input);
            if (value == null || !value.isFinite || value.abs() > 3600) {
              update(() => error = '请输入 -3600 至 3600 之间的有限秒数');
            } else {
              Navigator.pop(context, value);
            }
          }

          return AlertDialog(
            title: Text('${_name(kind)} · 本集时间偏移'),
            content: TextFormField(
              initialValue: input,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              decoration: InputDecoration(
                suffixText: '秒',
                helperText: '正数延后，负数提前；只影响此作品此集此来源',
                errorText: error,
              ),
              onChanged: (value) => input = value,
              onFieldSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 0.0),
                child: const Text('重置为 0'),
              ),
              FilledButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      ),
    );
    if (value != null && mounted && bindingKey == widget.session.bindingKey) {
      await _guard(() => widget.session.setOffset(kind, value));
    }
  }

  Future<void> _pickEpisode(DanmakuProviderKind kind) async {
    final bindingKey = widget.session.bindingKey;
    final state = widget.session.source(kind);
    final episodes = state.episodes;
    final selectedId = state.selected?.id;
    final selected = await showModalBottomSheet<DanmakuEpisodeChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: DanmakuEpisodePicker(
            title: '${_name(kind)} · 选择真实分集',
            episodes: episodes,
            selectedId: selectedId,
          ),
        ),
      ),
    );
    if (selected != null &&
        mounted &&
        bindingKey == widget.session.bindingKey) {
      await _guard(() => widget.session.chooseEpisode(selected));
    }
  }

  static String _name(DanmakuProviderKind kind) => switch (kind) {
    DanmakuProviderKind.bilibili => 'B站',
    DanmakuProviderKind.animeko => 'Animeko',
    DanmakuProviderKind.gamer => 'Gamer 动画疯',
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final theme = Theme.of(context);
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .82,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('弹幕来源 / 匹配', style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text(
                  'B站、Gamer 动画疯与 Animeko 独立池，可分别开关。匿名只读，不提供发送，不会影响视频播放；各源仍受内容覆盖与网络条件限制。',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('danmaku-source-all'),
                      label: const Text('全部'),
                      selected:
                          session.enabled &&
                          DanmakuProviderKind.values.every(session.includes),
                      onSelected: (_) => _guard(() async {
                        await session.selectSources(
                          DanmakuProviderKind.values.toSet(),
                        );
                        await widget.onEnabledChanged(true);
                      }),
                    ),
                    for (final kind in DanmakuProviderKind.values)
                      FilterChip(
                        key: ValueKey('danmaku-source-${kind.name}'),
                        label: Text(_name(kind)),
                        selected: session.includes(kind),
                        onSelected: (value) => _guard(() async {
                          final sources = {
                            for (final source in DanmakuProviderKind.values)
                              if (session.includes(source)) source,
                          };
                          if (value) {
                            sources.add(kind);
                          } else {
                            sources.remove(kind);
                          }
                          await session.selectSources(sources);
                          if (value) await widget.onEnabledChanged(true);
                        }),
                      ),
                    ChoiceChip(
                      key: const ValueKey('danmaku-source-off'),
                      label: const Text('关'),
                      selected: !session.enabled,
                      onSelected: (_) =>
                          _guard(() => widget.onEnabledChanged(false)),
                    ),
                  ],
                ),
                if (session.subjectId == null) ...[
                  const SizedBox(height: 12),
                  Text(
                    session.associationError ??
                        '尚未关联正确季度的 Bangumi 条目。不会拿播放站数字 ID 猜测弹幕。',
                  ),
                  const Text(
                    '查找条目后，在其「选择来源」中选择当前播放站作品建立关联；也可用 B站或动画疯官方 URL 手动纠正。',
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: widget.onAssociate,
                      icon: const Icon(Icons.link),
                      label: const Text('查找 Bangumi 动画条目'),
                    ),
                  ),
                ],
                for (final kind in DanmakuProviderKind.values) ...[
                  const SizedBox(height: 12),
                  _sourceCard(kind),
                ],
                const SizedBox(height: 16),
                _referenceEditor(
                  kind: DanmakuProviderKind.bilibili,
                  controller: _reference,
                  title: 'B站官方链接纠正',
                  hint: 'https://www.bilibili.com/bangumi/play/ep…',
                  description: '支持官方 ep / ss / md 完整 HTTPS URL。',
                  submit: () => session.setBilibiliReference(_reference.text),
                ),
                const SizedBox(height: 16),
                _referenceEditor(
                  kind: DanmakuProviderKind.gamer,
                  controller: _gamerReference,
                  title: '动画疯官方链接纠正',
                  hint: 'https://ani.gamer.com.tw/animeVideo.php?sn=…',
                  description: '支持官方播放页 animeVideo.php 或作品页 animeRef.php。',
                  submit: () => session.setGamerReference(_gamerReference.text),
                ),
                if (_inputError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _inputError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                const Text('匹配与秒数偏移按作品＋章节保存，最多保留 128 项；不缓存视频，不保存无界播放历史。'),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _referenceEditor({
    required DanmakuProviderKind kind,
    required TextEditingController controller,
    required String title,
    required String hint,
    required String description,
    required Future<void> Function() submit,
  }) {
    final available = widget.session.enabled && widget.session.includes(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Text('$description 绑定仅用于当前作品与章节，不改变视频来源。'),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('danmaku-${kind.name}-url'),
          controller: controller,
          enabled: available,
          decoration: InputDecoration(
            labelText: hint,
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _guard(submit),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: available ? () => _guard(submit) : null,
            icon: const Icon(Icons.manage_search),
            label: const Text('读取真实分集'),
          ),
        ),
      ],
    );
  }

  Widget _sourceCard(DanmakuProviderKind kind) {
    final session = widget.session;
    final state = session.source(kind);
    final available = session.enabled && session.includes(kind);
    final status = !available
        ? '已关闭'
        : state.loading
        ? '正在读取…'
        : state.error != null
        ? '读取失败'
        : state.selected != null
        ? state.comments.isEmpty
            ? '已匹配，本集暂无弹幕'
            : '已载入 ${state.comments.length} 条'
        : state.episodes.isEmpty
        ? session.subjectId == null
            ? '等待作品关联或官方链接'
            : '该来源未找到匹配季度 / 分集'
        : '需要手动选择分集';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_name(kind)} · $status',
              key: ValueKey('danmaku-status-${kind.name}'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (state.loading)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (state.selected != null) Text(state.selected!.title),
            if (state.error != null) SelectableText(state.error!),
            Text(
              '时间偏移 ${state.offsetSeconds > 0 ? '+' : ''}${state.offsetSeconds} 秒（正数延后 / 负数提前）',
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: available && state.episodes.isNotEmpty
                      ? () => _pickEpisode(kind)
                      : null,
                  icon: const Icon(Icons.playlist_play),
                  label: const Text('选择分集'),
                ),
                TextButton.icon(
                  onPressed: available
                      ? () => _guard(() => session.retry(kind))
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                TextButton(
                  onPressed: () => _offset(kind),
                  child: const Text('调整偏移'),
                ),
                TextButton(
                  onPressed: () => _guard(() => session.resetMatch(kind)),
                  child: const Text('恢复自动匹配'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
