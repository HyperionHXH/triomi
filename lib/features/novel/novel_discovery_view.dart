import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../sources/source_account_entries.dart';
import 'novel_book_card.dart';

class NovelDiscoveryView extends ConsumerStatefulWidget {
  const NovelDiscoveryView({super.key});

  @override
  ConsumerState<NovelDiscoveryView> createState() => _NovelDiscoveryViewState();
}

class _NovelChannel {
  final scroll = ScrollController();
  final items = <MediaItem>[];
  int nextPage = 1;
  int generation = 0;
  bool loading = false;
  bool started = false;
  bool ended = false;
  bool replaceOnSuccess = false;
  String? error;
  SourceErrorType? errorType;
  bool needsLogin = false;
  SourceRequestCancellation? owner;
}

class _NovelDiscoveryViewState extends ConsumerState<NovelDiscoveryView> {
  String? _sourceId;
  final _feeds = <String, String>{};
  final _channels = <(String, String), _NovelChannel>{};

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(preferencesProvider);
    _sourceId = preferences.get<String>('novel.discovery.source');
    final saved = preferences.get<Map<dynamic, dynamic>>(
      'novel.discovery.feeds',
    );
    if (saved != null) {
      for (final entry in saved.entries) {
        if (entry.key is String && entry.value is String) {
          _feeds[entry.key as String] = entry.value as String;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final channel in _channels.values) {
      channel.generation++;
      channel.owner?.cancel('已离开小说发现');
      channel.scroll.dispose();
    }
    super.dispose();
  }

  Future<void> _load(
    SourceEntry entry,
    DiscoverFeed feed,
    _NovelChannel channel, {
    bool reset = false,
  }) async {
    if (channel.loading && !reset) return;
    if (channel.ended && !reset) return;
    channel.owner?.cancel('小说频道请求已替换');
    final owner = SourceRequestCancellation();
    channel.owner = owner;
    final generation = reset ? ++channel.generation : channel.generation;
    if (reset) {
      channel.nextPage = 1;
      channel.ended = false;
      channel.replaceOnSuccess = true;
    }
    final replacing = channel.replaceOnSuccess;
    setState(() {
      channel.loading = true;
      channel.started = true;
      channel.error = null;
      channel.errorType = null;
      channel.needsLogin = false;
    });
    try {
      final source = entry.source;
      // LK HTTP requests inherit this owner through the request Zone. LNS Hub
      // invocations may still finish; cancelled/late responses never publish.
      final books = await owner
          .run(
            () => (source as DiscoverProvider).discover(
              feed,
              page: channel.nextPage,
            ),
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              owner.cancel('小说频道请求超时');
              throw TimeoutException('小说频道请求超时');
            },
          );
      if (!mounted ||
          channel.generation != generation ||
          owner.cancelled ||
          !identical(channel.owner, owner)) {
        return;
      }
      final valid = books
          .where(
            (book) =>
                book.type == MediaType.novel &&
                book.sourceId == entry.descriptor.id,
          )
          .toList();
      final previous = replacing
          ? <(String, String)>{}
          : channel.items.map((book) => (book.sourceId, book.remoteId)).toSet();
      final fresh = valid
          .where((book) => previous.add((book.sourceId, book.remoteId)))
          .toList();
      setState(() {
        if (replacing) channel.items.clear();
        channel.replaceOnSuccess = false;
        channel.items.addAll(fresh);
        // Sources own their page sizes and fixed-rank slicing. Empty or repeated
        // pages end the list; guessing a common page size truncates real feeds.
        channel.ended = valid.isEmpty || fresh.isEmpty;
        channel.nextPage++;
        channel.loading = false;
      });
    } catch (error) {
      if (!mounted ||
          channel.generation != generation ||
          !identical(channel.owner, owner)) {
        return;
      }
      setState(() {
        channel.loading = false;
        channel.errorType = SourceException.wrap(
          error,
          sourceId: entry.descriptor.id,
        ).type;
        channel.needsLogin =
            error is SourceException && error.type == SourceErrorType.auth;
        channel.error = error is SourceException
            ? SourceRegistry.describeError(error, entry.descriptor.name)
            : '${entry.descriptor.name}：${SourceException.sanitizeMessage('$error')}';
      });
    } finally {
      if (identical(channel.owner, owner)) channel.owner = null;
    }
  }

  Future<void> _account(SourceEntry entry) async {
    await context.push(accountRouteFor(entry.descriptor.id));
    if (mounted) ref.invalidate(sourcesProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sourcesProvider, (previous, next) {
      if (!next.isLoading || previous?.asData == null) return;
      // Registry changes include account switches and adapter replacements.
      // A retained channel must not expose the previous session's results.
      for (final channel in _channels.values) {
        channel.generation++;
        channel.owner?.cancel('小说来源或账号已更改');
        channel.owner = null;
        channel.items.clear();
        channel.nextPage = 1;
        channel.loading = false;
        channel.started = false;
        channel.ended = false;
        channel.replaceOnSuccess = false;
        channel.error = null;
        channel.needsLogin = false;
      }
    });
    return ref
        .watch(sourcesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyStateView(
            icon: Icons.cloud_off_outlined,
            title: '小说来源加载失败',
            message: '$error',
            action: OutlinedButton(
              onPressed: () => ref.read(sourcesProvider.notifier).refresh(),
              child: const Text('重试'),
            ),
          ),
          data: _body,
        );
  }

  Widget _body(SourceRegistrySnapshot snapshot) {
    final entries = snapshot
        .enabledWith(SourceCapability.discover)
        .where(
          (entry) =>
              entry.descriptor.type == MediaType.novel &&
              entry.source is DiscoverProvider &&
              (entry.source as DiscoverProvider).feeds.isNotEmpty,
        )
        .toList();
    if (entries.isEmpty) {
      return EmptyStateView(
        icon: Icons.menu_book_outlined,
        title: '暂无已启用的小说发现来源',
        message: '启用轻之国度或轻书架后浏览各站真实频道。',
        action: OutlinedButton(
          onPressed: () => context.push('${AppRoutes.sources}?type=novel'),
          child: const Text('小说来源与账号'),
        ),
      );
    }
    final entry =
        entries.where((e) => e.descriptor.id == _sourceId).firstOrNull ??
        entries.first;
    final sourceId = entry.descriptor.id;
    final feeds = (entry.source as DiscoverProvider).feeds;
    final feed =
        feeds.where((f) => f.id == _feeds[sourceId]).firstOrNull ??
        feeds.where((f) => f.id == 'hot' || f.id == 'popular').firstOrNull ??
        feeds.first;
    final channel = _channels.putIfAbsent((
      sourceId,
      feed.id,
    ), _NovelChannel.new);
    if (!channel.started) {
      channel.started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(entry, feed, channel);
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownMenu<String>(
                label: const Text('站点'),
                initialSelection: sourceId,
                dropdownMenuEntries: [
                  for (final candidate in entries)
                    DropdownMenuEntry(
                      value: candidate.descriptor.id,
                      label: candidate.descriptor.name,
                    ),
                ],
                onSelected: (id) {
                  setState(() => _sourceId = id);
                  unawaited(
                    ref
                        .read(preferencesProvider)
                        .set('novel.discovery.source', id),
                  );
                },
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final candidate in feeds)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(candidate.name),
                    selected: candidate.id == feed.id,
                    onSelected: (_) {
                      setState(() {
                        _feeds[sourceId] = candidate.id;
                      });
                      unawaited(
                        ref
                            .read(preferencesProvider)
                            .set(
                              'novel.discovery.feeds',
                              Map<String, String>.of(_feeds),
                            ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Divider(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(entry, feed, channel, reset: true),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.extentAfter < 400 &&
                    channel.error == null &&
                    !channel.loading &&
                    !channel.ended) {
                  _load(entry, feed, channel);
                }
                return false;
              },
              child: ListView.separated(
                key: PageStorageKey('novel-discovery-$sourceId-${feed.id}'),
                controller: channel.scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.md),
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.sm),
                itemCount: channel.items.length + 1,
                itemBuilder: (context, index) {
                  if (index < channel.items.length) {
                    return NovelBookCard(
                      item: channel.items[index],
                      sourceLabel: entry.descriptor.name,
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        if (channel.loading)
                          const CircularProgressIndicator()
                        else if (channel.error != null) ...[
                          const Icon(Icons.cloud_off_outlined, size: 32),
                          const SizedBox(height: 12),
                          Text(
                            '${entry.descriptor.name} · ${channel.errorType?.label ?? '暂时无法加载'}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (entry.source is AccountProvider)
                            Text(
                              (entry.source as AccountProvider).isLoggedIn
                                  ? '本站账号已登录；站点可能要求重新认证。'
                                  : '本站账号未登录；公开频道是否可访问由站点决定。',
                            ),
                          ExpansionTile(
                            title: const Text('错误详情'),
                            childrenPadding: const EdgeInsets.all(12),
                            children: [SelectableText(channel.error!)],
                          ),
                          Wrap(
                            spacing: 12,
                            children: [
                              OutlinedButton(
                                onPressed: () => _load(entry, feed, channel),
                                child: const Text('重试'),
                              ),
                              if (channel.needsLogin &&
                                  entry.source is AccountProvider)
                                FilledButton(
                                  onPressed: () => _account(entry),
                                  child: Text('${entry.descriptor.name}账号'),
                                ),
                            ],
                          ),
                        ] else if (channel.ended)
                          Text(channel.items.isEmpty ? '当前频道暂无书籍' : '已经到底了')
                        else
                          OutlinedButton(
                            onPressed: () => _load(entry, feed, channel),
                            child: const Text('加载更多'),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
