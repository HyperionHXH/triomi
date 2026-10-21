import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/models/source_exception.dart';
import '../anime/data/anime_collection_service.dart';
import '../tracking/data/bangumi_client.dart';

/// Edits only the current user's subject collection review.
class AnimeReviewDialog extends ConsumerStatefulWidget {
  const AnimeReviewDialog({super.key, required this.item});
  final MediaItem item;

  @override
  ConsumerState<AnimeReviewDialog> createState() => _AnimeReviewDialogState();
}

class _AnimeReviewDialogState extends ConsumerState<AnimeReviewDialog> {
  final _comment = TextEditingController();
  late AnimeCollectionService _service;
  BangumiCollection? _existing;
  bool _loading = true, _loaded = false, _saving = false, _private = false;
  int _rate = 0;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = ref.read(animeCollectionServiceProvider);
    unawaited(_load());
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await _service.status(widget.item);
      if (!mounted) return;
      setState(() {
        _existing = value;
        _rate = (value?.rate ?? 0).clamp(0, 10);
        if (value?.localStatus == 'want') _rate = 0;
        _private = value?.private ?? false;
        _comment.text = value?.comment ?? '';
        _loaded = true;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = SourceException.sanitizeMessage('$error');
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = await _service.updateReview(
        widget.item,
        rate: _rate,
        comment: _comment.text,
        private: _private,
        newStatus: _status,
      );
      if (mounted) Navigator.pop(context, value);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = SourceException.sanitizeMessage('$error');
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Disposing the bound service invalidates both in-flight reads and writes.
    final service = ref.watch(animeCollectionServiceProvider);
    final changedAccount = !identical(service, _service);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('我的评分与吐槽'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.item.title),
                const SizedBox(height: 12),
                if (changedAccount)
                  const Text('Bangumi 账号已变化，请关闭后重新打开；旧草稿不会提交到新账号。')
                else if (_loading)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  if (!_loaded && _error != null && !_saving)
                    TextButton(onPressed: _load, child: const Text('重试读取我的吐槽')),
                  if (_loaded) ...[
                    if (_existing == null) ...[
                      const Text('发表评分与吐槽需要在 Bangumi 收藏此作品；请选择收藏状态。'),
                      DropdownButtonFormField<String>(
                        initialValue: _status,
                        decoration: const InputDecoration(
                          labelText: 'Bangumi 收藏状态',
                        ),
                        items: [
                          for (final entry in animeCollectionStatuses.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) => setState(() {
                                _status = value!;
                                if (_status == 'want') _rate = 0;
                              }),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      key: const ValueKey('anime-review-rating'),
                      initialValue:
                          _existing?.localStatus == 'want' || _status == 'want'
                          ? 0
                          : _rate,
                      decoration: InputDecoration(
                        labelText: '评分',
                        helperText:
                            _existing?.localStatus == 'want' ||
                                _status == 'want'
                            ? 'Bangumi「想看」条目不保存评分；选择其他收藏状态后才可评分。'
                            : null,
                      ),
                      items: [
                        for (var value = 0; value <= 10; value++)
                          DropdownMenuItem(
                            value: value,
                            enabled:
                                !(_existing?.localStatus == 'want' ||
                                    _status == 'want'),
                            child: Text(value == 0 ? '未评分' : '$value / 10 分'),
                          ),
                      ],
                      onChanged:
                          _saving ||
                              _existing?.localStatus == 'want' ||
                              _status == 'want'
                          ? null
                          : (value) => setState(() => _rate = value!),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('anime-review-comment'),
                      controller: _comment,
                      enabled: !_saving,
                      minLines: 3,
                      maxLines: 8,
                      maxLength: 380,
                      decoration: const InputDecoration(
                        labelText: '吐槽',
                        hintText: '写下你对这部作品的感想',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('仅自己可见'),
                      value: _private,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _private = value),
                    ),
                    const Text('提交到你自己的 Bangumi 账号；不会修改已有收藏状态、标签或观看进度。'),
                  ],
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('anime-review-submit'),
            onPressed:
                changedAccount ||
                    _loading ||
                    _saving ||
                    !_loaded ||
                    (_existing == null && _status == null)
                ? null
                : _save,
            child: Text(_saving ? '提交中…' : '提交评分与吐槽'),
          ),
        ],
      ),
    );
  }
}
