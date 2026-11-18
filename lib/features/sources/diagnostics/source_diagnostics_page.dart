import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/media_type.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_registry.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/page_scaffold.dart';
import 'source_diagnostics_export.dart';
import 'source_diagnostics_models.dart';
import 'source_diagnostics_providers.dart';
import 'source_diagnostics_redaction.dart';
import 'source_diagnostics_service.dart';
import 'source_diagnostics_store.dart';

/// Manual, one-request-at-a-time source diagnostics.
///
/// It intentionally has no batch mode and no automatic startup request. The
/// notice in the UI tells the user that pressing "测试搜索" sends exactly one
/// search request to the selected source.
class SourceDiagnosticsPage extends ConsumerStatefulWidget {
  const SourceDiagnosticsPage({super.key, this.initialSourceId});

  final String? initialSourceId;

  @override
  ConsumerState<SourceDiagnosticsPage> createState() =>
      _SourceDiagnosticsPageState();
}

class _SourceDiagnosticsPageState extends ConsumerState<SourceDiagnosticsPage> {
  final TextEditingController _keyword = TextEditingController();
  String? _selectedId;
  bool _selectionInitialized = false;
  SourceDiagnosticsSourceRecord? _selectedRecord;
  bool _historyLoading = false;
  bool _historyReadFailed = false;
  bool _running = false;
  int _runGeneration = 0;
  int _historyGeneration = 0;
  SourceDiagnosticsTestResult? _lastResult;
  String? _localNotice;
  SourceDiagnosticsService? _service;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialSourceId;
    _selectionInitialized = widget.initialSourceId != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadHistory(_selectedId));
    });
  }

  @override
  void dispose() {
    _runGeneration++;
    _historyGeneration++;
    _service?.cancel();
    _keyword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(sourceDiagnosticsServiceProvider);
    if (!identical(service, _service)) {
      _service?.cancel();
      _service = service;
    }
    final snapshot = ref.watch(sourceDiagnosticsSnapshotProvider);
    return PageScaffold(
      title: '来源诊断中心',
      actions: <Widget>[
        IconButton(
          key: const ValueKey('source-diagnostics-refresh'),
          tooltip: '刷新来源列表',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          key: const ValueKey('source-diagnostics-export'),
          tooltip: '导出诊断 JSON',
          onPressed: () {
            unawaited(_showExport());
          },
          icon: const Icon(Icons.ios_share),
        ),
      ],
      child: snapshot.when(
        loading: () => const _LoadingView(),
        error: (error, stackTrace) => EmptyStateView(
          icon: Icons.error_outline,
          title: '来源注册表不可用',
          message: '无法读取来源元数据；诊断不会执行任何来源脚本。',
          action: FilledButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
        data: (snapshot) => _buildData(context, snapshot),
      ),
    );
  }

  Widget _buildData(BuildContext context, SourceRegistrySnapshot snapshot) {
    final choices = _choices(snapshot);
    _ensureSelection(choices);
    final selected = choices
        .where((choice) => choice.id == _selectedId)
        .firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        const _NoticeCard(),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('选择来源', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              if (choices.isEmpty)
                Text(
                  '当前注册表中没有来源。请先在来源管理中导入或启用来源。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.palette.mutedForeground,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey<String>(
                    'source-diagnostics-picker-${_selectedId ?? ''}',
                  ),
                  initialValue: selected?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '来源',
                    helperText: '显示当前注册表状态；停用或无效的来源不会被测试执行',
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final choice in choices)
                      DropdownMenuItem<String>(
                        value: choice.id,
                        child: Text(
                          choice.pickerLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _onSourceChanged,
                ),
              if (selected != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                _SourceStatusLine(choice: selected),
                if (selected.failure != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  _InlineNotice(
                    icon: Icons.report_outlined,
                    color: Theme.of(context).colorScheme.error,
                    title: '规则无法加载',
                    message:
                        '${selected.failure!.message}\n诊断不会加载或执行此无效脚本；请先在来源管理中修复、重新导入或删除。',
                  ),
                ],
                if (selected.isMissing) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  const _InlineNotice(
                    icon: Icons.help_outline,
                    title: '当前来源不可用',
                    message:
                        '当前注册表中找不到该来源，可能已被删除、替换或尚未加载完成。诊断不会执行任何脚本。',
                  ),
                ],
              ],
            ],
          ),
        ),
        if (selected != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _buildTestCard(context, selected),
        ],
        const SizedBox(height: AppSpacing.md),
        _buildHistoryCard(context, selected),
        if (snapshot.failures.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _buildFailuresCard(context, snapshot.failures),
        ],
      ],
    );
  }

  Widget _buildTestCard(BuildContext context, _SourceChoice selected) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final canRun = selected.canRun;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('手动测试搜索', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '每次点击只会向所选来源发送 1 次搜索请求。不会自动批量测试、登录或写入站点，也不会绕过停用状态。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
            ),
          ),
          if (!canRun) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _InlineNotice(
              icon: Icons.info_outline,
              title: selected.statusLabel,
              message: selected.explanation,
            ),
          ] else ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('source-diagnostics-keyword'),
              controller: _keyword,
              enabled: !_running,
              maxLength: 200,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: '测试关键词',
                hintText: '输入一个词，仅用于本次请求',
                helperText: '关键词不会写入诊断历史或导出内容',
              ),
              onSubmitted: (_) {
                if (!_running) unawaited(_runTest(selected));
              },
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                FilledButton.icon(
                  key: const ValueKey('source-diagnostics-run'),
                  onPressed: _running
                      ? null
                      : () {
                          unawaited(_runTest(selected));
                        },
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(_running ? '测试中…' : '测试搜索'),
                ),
                if (_running)
                  OutlinedButton.icon(
                    key: const ValueKey('source-diagnostics-cancel'),
                    onPressed: _cancelCurrent,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('取消测试'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '请求有 ${SourceDiagnosticsService.defaultTimeout.inSeconds} 秒上限；两次测试至少间隔约 ${SourceDiagnosticsService.defaultMinimumInterval.inSeconds} 秒。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          ],
          if (_localNotice != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _InlineNotice(
              icon: Icons.info_outline,
              title: '提示',
              message: _localNotice!,
            ),
          ],
          if (_lastResult != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _buildResult(context, _lastResult!),
          ],
        ],
      ),
    );
  }

  Widget _buildResult(BuildContext context, SourceDiagnosticsTestResult result) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final category = result.category ?? SourceDiagnosticsCategory.unknown;
    if (result.status == SourceDiagnosticsRunStatus.success) {
      final count = result.resultCount ?? 0;
      return _InlineNotice(
        icon: Icons.check_circle_outline,
        color: palette.updateBadge,
        title: '搜索成功 · ${result.latency.inMilliseconds} ms',
        message: count == 0
            ? '请求成功，返回 0 条结果。空结果是有效的搜索结果，不代表来源损坏。'
            : '请求成功，返回 $count 条结果。',
      );
    }
    if (result.status == SourceDiagnosticsRunStatus.failure) {
      final status = result.statusCode == null
          ? ''
          : ' · HTTP ${result.statusCode}';
      return _InlineNotice(
        icon: Icons.error_outline,
        color: theme.colorScheme.error,
        title: '${category.label}$status · ${result.latency.inMilliseconds} ms',
        message: _categoryGuidance(category),
      );
    }
    return _InlineNotice(
      icon: Icons.info_outline,
      title: result.status.label,
      message: _statusMessage(result.status),
    );
  }

  Widget _buildHistoryCard(BuildContext context, _SourceChoice? selected) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final record = _selectedRecord;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('本机诊断历史', style: theme.textTheme.titleMedium),
              ),
              TextButton.icon(
                key: const ValueKey('source-diagnostics-export-all'),
                onPressed: () {
                  unawaited(_showExport());
                },
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('导出全部 JSON'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '每个来源最多保留最近 ${SourceDiagnosticsStore.maxRunsPerSource} 次、总计最多 ${SourceDiagnosticsStore.maxSources} 个来源。记录不含关键词、原始错误、URL、请求头、响应内容或凭据。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
            ),
          ),
          if (_historyLoading) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            const LinearProgressIndicator(),
          ],
          if (_historyReadFailed) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            const _InlineNotice(
              icon: Icons.warning_amber_outlined,
              title: '本地历史读取失败',
              message: '这不影响来源本身；可稍后重试或清除本机诊断记录。',
            ),
          ],
          if (selected == null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Text(
              '请选择一个来源查看其本机记录。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          ] else if (!_historyLoading && record == null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Text(
              '该来源还没有本机诊断记录。手动测试后只会保存安全摘要。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          ] else if (record != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _HistoryLine(
              icon: Icons.check_circle_outline,
              color: palette.updateBadge,
              title: '最近成功',
              value: record.lastSuccess == null
                  ? '无'
                  : _runSummary(record.lastSuccess!),
            ),
            const SizedBox(height: AppSpacing.xs),
            _HistoryLine(
              icon: Icons.error_outline,
              color: theme.colorScheme.error,
              title: '最近失败',
              value: record.lastFailure == null
                  ? '无'
                  : _runSummary(record.lastFailure!),
            ),
            if (record.runs.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              Text('最近记录', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              for (var index = 0; index < record.runs.length; index++) ...<Widget>[
                if (index > 0) const Divider(height: AppSpacing.md),
                _RunRow(run: record.runs[index]),
              ],
            ],
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const ValueKey('source-diagnostics-copy'),
                  onPressed: () {
                    unawaited(_copyFeedback());
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('复制脱敏反馈'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('source-diagnostics-clear'),
                  onPressed: () {
                    unawaited(_confirmClearSelected());
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清除该来源历史'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFailuresCard(
    BuildContext context,
    List<SourceFailure> failures,
  ) {
    final theme = Theme.of(context);
    final palette = context.palette;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('规则加载失败', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '这些来源不会出现在可测试列表中，也不会加载或执行其无效脚本。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (var index = 0; index < failures.length; index++) ...<Widget>[
            if (index > 0) const Divider(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.report_outlined,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        sanitizeDiagnosticsLabel(
                          failures[index].name,
                          sourceId: failures[index].id,
                        ),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        failures[index].message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _refresh() {
    ref.invalidate(sourceDiagnosticsSnapshotProvider);
  }

  void _onSourceChanged(String? sourceId) {
    if (sourceId == null || sourceId == _selectedId) return;
    _service?.cancel();
    _runGeneration++;
    _historyGeneration++;
    _keyword.clear();
    setState(() {
      _selectedId = sourceId;
      _running = false;
      _lastResult = null;
      _localNotice = null;
      _selectedRecord = null;
      _historyReadFailed = false;
    });
    unawaited(_loadHistory(sourceId));
  }

  Future<void> _runTest(_SourceChoice selected) async {
    if (_running || !selected.canRun) return;
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty) {
      setState(() => _localNotice = '请输入测试关键词；关键词只用于本次请求，不保存。');
      return;
    }
    final service = _service;
    if (service == null) return;
    final sourceId = selected.id;
    final generation = ++_runGeneration;
    setState(() {
      _running = true;
      _lastResult = null;
      _localNotice = null;
    });
    SourceDiagnosticsTestResult result;
    try {
      result = await service.testSearch(sourceId: sourceId, keyword: keyword);
    } catch (_) {
      if (!mounted || generation != _runGeneration) return;
      setState(() {
        _running = false;
        _localNotice = '测试未能完成；未保存任何原始错误或请求内容。请稍后重试。';
      });
      return;
    }
    if (!mounted || generation != _runGeneration || _selectedId != sourceId) {
      return;
    }
    setState(() {
      _running = false;
      _lastResult = result;
    });
    await _loadHistory(sourceId);
  }

  void _cancelCurrent() {
    if (!_running) return;
    _service?.cancel();
    _runGeneration++;
    setState(() {
      _running = false;
      _lastResult = null;
      _localNotice = '已取消本次测试；迟到的结果不会发布，也不会写入历史。';
    });
  }

  Future<void> _loadHistory(String? sourceId) async {
    final generation = ++_historyGeneration;
    if (sourceId == null) {
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _selectedRecord = null;
        _historyLoading = false;
        _historyReadFailed = false;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _historyLoading = true;
        _historyReadFailed = false;
      });
    }
    SourceDiagnosticsHistory history = const SourceDiagnosticsHistory();
    var failed = false;
    try {
      history = await ref.read(sourceDiagnosticsStoreProvider).load();
    } catch (_) {
      failed = true;
    }
    if (!mounted ||
        generation != _historyGeneration ||
        _selectedId != sourceId) {
      return;
    }
    setState(() {
      _selectedRecord = history.forSource(sourceId);
      _historyLoading = false;
      _historyReadFailed = failed;
    });
  }

  Future<void> _copyFeedback() async {
    final record = _selectedRecord;
    if (record == null) {
      _message('没有可复制的诊断记录');
      return;
    }
    await Clipboard.setData(
      ClipboardData(text: buildSourceDiagnosticsFeedback(record)),
    );
    if (!mounted) return;
    _message('已复制脱敏诊断反馈');
  }

  Future<void> _confirmClearSelected() async {
    final sourceId = _selectedId;
    if (sourceId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除该来源的诊断历史？'),
        content: const Text(
          '只会删除本机保存的该来源诊断记录；不会修改来源、规则、账号、书架或下载。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || sourceId != _selectedId) return;
    try {
      await ref.read(sourceDiagnosticsStoreProvider).clearSource(sourceId);
    } catch (_) {
      if (mounted) _message('无法清除本机诊断历史，请稍后重试');
      return;
    }
    if (!mounted) return;
    await _loadHistory(sourceId);
    if (mounted) _message('已清除该来源的诊断历史');
  }

  Future<void> _showExport() async {
    SourceDiagnosticsHistory history;
    try {
      history = await ref.read(sourceDiagnosticsStoreProvider).load();
    } catch (_) {
      if (mounted) _message('无法读取本机诊断历史');
      return;
    }
    if (!mounted) return;
    final text = encodeSourceDiagnosticsExport(
      history,
      exportedAt: DateTime.now(),
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出诊断 JSON'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              unawaited(_copyExport(dialogContext, text));
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyExport(BuildContext dialogContext, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (dialogContext.mounted) Navigator.pop(dialogContext);
    if (!mounted) return;
    _message('已复制脱敏诊断 JSON');
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  List<_SourceChoice> _choices(SourceRegistrySnapshot snapshot) {
    final choices = <_SourceChoice>[
      for (final entry in snapshot.entries) _SourceChoice.entry(entry),
      for (final failure in snapshot.failures)
        if (!snapshot.entries.any(
          (entry) => entry.descriptor.id == failure.id,
        ))
          _SourceChoice.failure(failure),
    ];
    if (_selectedId != null &&
        !choices.any((choice) => choice.id == _selectedId)) {
      choices.add(_SourceChoice.missing(_selectedId!));
    }
    return choices;
  }

  void _ensureSelection(List<_SourceChoice> choices) {
    if (_selectionInitialized) return;
    _selectionInitialized = true;
    final firstRunnable = choices
        .where((choice) => choice.canRun)
        .firstOrNull;
    final candidate =
        widget.initialSourceId ?? firstRunnable?.id ?? choices.firstOrNull?.id;
    if (candidate == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedId != null) return;
      setState(() => _selectedId = candidate);
      unawaited(_loadHistory(candidate));
    });
  }
}

class _SourceChoice {
  const _SourceChoice({
    required this.id,
    required this.name,
    required this.statusLabel,
    required this.explanation,
    required this.type,
    this.entry,
    this.failure,
  });

  factory _SourceChoice.entry(SourceEntry entry) {
    final supported = entry.source is SearchProvider;
    final status = !entry.enabled
        ? '已停用'
        : !supported
        ? '已启用 · 不支持搜索'
        : !entry.source.isReady
        ? '已启用 · 待加载'
        : '已启用 · 可搜索';
    final explanation = !entry.enabled
        ? '来源已停用。诊断不会自动启用，也不会绕过停用状态；请先在来源管理中启用。'
        : !supported
        ? '该来源没有实现搜索能力（SearchProvider），无法执行搜索诊断。此状态不代表来源损坏。'
        : '来源已启用并支持搜索。';
    return _SourceChoice(
      id: entry.descriptor.id,
      name: entry.descriptor.name,
      statusLabel: status,
      explanation: explanation,
      type: entry.descriptor.type,
      entry: entry,
    );
  }

  factory _SourceChoice.failure(SourceFailure failure) => _SourceChoice(
    id: failure.id,
    name: failure.name,
    statusLabel: '规则无效',
    explanation: '该来源的规则无法加载。诊断不会执行无效脚本；请先在来源管理中修复或重新导入。',
    type: failure.type,
    failure: failure,
  );

  factory _SourceChoice.missing(String id) => _SourceChoice(
    id: id,
    name: '',
    statusLabel: '当前注册表未找到',
    explanation: '当前注册表中找不到该来源，可能已被删除、替换或尚未加载完成。',
    type: null,
  );

  final String id;
  final String name;
  final String statusLabel;
  final String explanation;
  final MediaType? type;
  final SourceEntry? entry;
  final SourceFailure? failure;

  bool get canRun =>
      entry != null && entry!.enabled && entry!.source is SearchProvider;

  bool get isMissing => entry == null && failure == null;

  String get displayName => sanitizeDiagnosticsLabel(name, sourceId: id);

  String get pickerLabel {
    final typeLabel = type?.label;
    return <String>[
      displayName,
      ?typeLabel,
      statusLabel,
    ].join(' · ');
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.privacy_tip_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('显式手动测试', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  '每次点击「测试搜索」只会向所选来源发送 1 次搜索请求。不会自动批量测试、不会登录或写入来源站点，也不会绕过停用状态。关键词只用于本次请求，不保存。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  '空结果（0 条）是成功的搜索，不代表来源损坏。失败只记录分类、HTTP 状态、耗时、版本与结果数量；不记录原始错误、URL、请求头、响应内容或凭据。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceStatusLine extends StatelessWidget {
  const _SourceStatusLine({required this.choice});

  final _SourceChoice choice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Chip(
          visualDensity: VisualDensity.compact,
          label: Text(choice.statusLabel),
        ),
        Text(
          choice.displayName,
          style: theme.textTheme.bodySmall?.copyWith(
            color: context.palette.mutedForeground,
          ),
        ),
        Text(
          '标识 ${diagnosticsSourceDigest(choice.id)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: context.palette.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.color,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = color ?? theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: 0.08),
        borderRadius: AppRadius.controlRadius,
        border: Border.all(color: resolved.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: resolved, size: 20),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xxs),
                Text(message, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryLine extends StatelessWidget {
  const _HistoryLine({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: color, size: 18),
        const SizedBox(width: AppSpacing.xs),
        SizedBox(
          width: 72,
          child: Text(title, style: theme.textTheme.bodySmall),
        ),
        Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.run});

  final SourceDiagnosticsRunRecord run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final title = run.isSuccess
        ? '成功 · ${run.resultCount ?? 0} 条结果'
        : '${run.category.label}${run.statusCode == null ? '' : ' · HTTP ${run.statusCode}'}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          run.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
          color: run.isSuccess ? palette.updateBadge : theme.colorScheme.error,
          size: 18,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: theme.textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                '${_formatTime(run.at)} · ${run.latencyMs} ms · app ${run.appVersion}'
                '${run.pluginVersion == null ? '' : ' · 来源 ${run.pluginVersion}'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CircularProgressIndicator(),
        SizedBox(height: AppSpacing.md),
        Text('正在加载来源注册表…'),
      ],
    ),
  );
}

String _runSummary(SourceDiagnosticsRunRecord run) {
  final parts = <String>[
    _formatTime(run.at),
    run.isSuccess ? '成功' : run.category.label,
  ];
  if (run.statusCode != null) parts.add('HTTP ${run.statusCode}');
  parts.add('${run.latencyMs} ms');
  if (run.resultCount != null) parts.add('${run.resultCount} 条结果');
  parts.add('app ${run.appVersion}');
  if (run.pluginVersion != null) parts.add('来源 ${run.pluginVersion}');
  return parts.join(' · ');
}

String _categoryGuidance(SourceDiagnosticsCategory category) =>
    switch (category) {
      SourceDiagnosticsCategory.success => '请求成功。',
      SourceDiagnosticsCategory.auth =>
        '来源报告需要登录或凭据无效（通常为 HTTP 401）。请到来源账号页检查登录状态。',
      SourceDiagnosticsCategory.permission =>
        '服务器拒绝了此次请求。403 也可能来自站点风控、地区限制或访问策略，不能仅凭它判断为登录过期或 Cloudflare 拦截。',
      SourceDiagnosticsCategory.rateLimited =>
        '站点限流（通常为 HTTP 429）。请稍后重试；本页两次测试至少间隔约 2 秒。',
      SourceDiagnosticsCategory.timeout => '请求在限定时间内没有返回。请检查网络，或稍后重试。',
      SourceDiagnosticsCategory.dns => '域名解析失败。请检查网络/DNS 设置或来源地址。',
      SourceDiagnosticsCategory.tls => 'TLS / 证书校验失败。可能是证书、代理或系统时间问题。',
      SourceDiagnosticsCategory.connection => '无法建立连接。请检查网络、代理或站点是否可达。',
      SourceDiagnosticsCategory.httpStatus =>
        '服务器返回了非成功 HTTP 状态。可结合状态码与站点状态页排查。',
      SourceDiagnosticsCategory.parser =>
        '请求已返回，但内容无法按来源规则解析。可能是站点改版、验证页面或规则不匹配。',
      SourceDiagnosticsCategory.notFound => '来源报告内容不存在。',
      SourceDiagnosticsCategory.network => '来源网络请求失败；没有足够结构化信息进一步细分原因。',
      SourceDiagnosticsCategory.cancelled => '请求已取消。',
      SourceDiagnosticsCategory.unknown => '无法归因到已知错误类别。这不代表来源一定损坏。',
    };

String _statusMessage(SourceDiagnosticsRunStatus status) => switch (status) {
  SourceDiagnosticsRunStatus.success => '请求成功。',
  SourceDiagnosticsRunStatus.failure => '请求失败。',
  SourceDiagnosticsRunStatus.sourceDisabled =>
    '来源已在注册表中停用。诊断不会自动启用，也不会绕过停用状态。',
  SourceDiagnosticsRunStatus.unsupported =>
    '该来源没有实现搜索能力（SearchProvider），无法执行搜索诊断。此状态不代表来源损坏。',
  SourceDiagnosticsRunStatus.invalidSource =>
    '该来源的规则无法加载。诊断不会执行无效脚本；请先在来源管理中修复或重新导入。',
  SourceDiagnosticsRunStatus.sourceUnavailable => '当前注册表中找不到该来源，可能已被删除或替换。',
  SourceDiagnosticsRunStatus.registryError => '无法读取来源注册表；未发送任何搜索请求。',
  SourceDiagnosticsRunStatus.busy => '上一项测试仍在进行，请等待其完成或取消后再试。',
  SourceDiagnosticsRunStatus.throttled => '两次测试之间至少间隔约 2 秒，请稍后再试。',
  SourceDiagnosticsRunStatus.cancelled => '测试已取消；迟到的结果不会发布，也不会写入历史。',
  SourceDiagnosticsRunStatus.keywordRequired => '请输入测试关键词；关键词只用于本次请求。',
};

String _formatTime(DateTime value) {
  final time = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}