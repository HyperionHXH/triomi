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
import '../../core/widgets/page_scaffold.dart';
import '../sources/source_account_entries.dart';
import 'novel_book_card.dart';

class NovelDiscoveryView extends ConsumerStatefulWidget {
  const NovelDiscoveryView({super.key});

  @override
  ConsumerState<NovelDiscoveryView> createState() => _NovelDiscoveryViewState();
}

class _NovelChannel {
  _NovelChannel({this.query = ''});
  final String query;
  final scroll = ScrollController();
  final items = <MediaItem>[];
  int nextPage = 1;
  int generation = 0;
  bool loading = false;
  bool started = false;
  bool ended = false;
  bool replaceOnSuccess = false;
  String? error;
  bool needsLogin = false;
  SourceRequestCancellation? owner;
}

class _NovelDiscoveryViewState extends ConsumerState<NovelDiscoveryView> {
  String? _sourceId;
  final _feeds = <String, String>{};
  final _queries = <String, String>{};
  final _queryEditors = <String, TextEditingController>{};
  final _channels = <(String, String, String), _NovelChannel>{};

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(preferencesProvider);
    _sourceId = preferences.get<String>('novel.discovery.source');
    final saved = preferences.get<Map<dynamic, dynamic>>('novel.discovery.feeds');
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
    for (final editor in _queryEditors.values) {
      editor.dispose();
    }
    for (final channel in _channels.values) {
      channel.generation++;
      channel.owner?.cancel('已离开小说发现');
      channel.scroll.dispose();
    }
    super.dispose();
  }

  void _cancelChannel(_NovelChannel channel, String reason) {
    channel.generation++;
    channel.owner?.cancel(reason);
    channel.owner = null;
    channel.loading = false;
    if (channel.items.isEmpty) channel.started = false;
  }

  void _applyQuery(String sourceId, String value, _NovelChannel previous) {
    final query = value.trim();
    if ((_queries[sourceId] ?? '') != query) {
      // Only the superseded request is cancelled. Retained source/channel
      // requests are not cancelled simply because another tab becomes visible.
      _cancelChannel(previous, '小说来源查询已改变');
    }
    _queries[sourceId] = query;
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
      channel.needsLogin = false;
    });
    try {
      final source = entry.source;
      // LK HTTP requests inherit this owner through the request Zone. LNS Hub
      // invocations may still finish; cancelled/late responses never publish.
      final books = await owner.run(
        () => channel.query.isNotEmpty && source is SearchProvider
            ? source.search(channel.query, page: channel.nextPage)
            : (source as DiscoverProvider).discover(
                feed,
                page: channel.nextPage,
              ),
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          owner.cancel('小说频道请求超时');
          throw TimeoutException('小说频道请求超时');
        },
      );
      if (!mounted || channel.generation != generation || owner.cancelled ||
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
      if (!mounted || channel.generation != generation ||
          !identical(channel.owner, owner)) {
        return;
      }
      setState(() {
        channel.loading = false;
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

  Future<void> _account(
    SourceEntry entry,
    DiscoverFeed feed,
    _NovelChannel channel,
  ) async {
    await context.push(accountRouteFor(entry.descriptor.id));
    if (mounted) await _load(entry, feed, channel, reset: true);
  }

  @override
  Widget build(BuildContext context) {
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
    final query = _queries[sourceId] ?? '';
    final editor = _queryEditors.putIfAbsent(
      sourceId,
      TextEditingController.new,
    );
    final channel = _channels.putIfAbsent((
      sourceId,
      query.isEmpty ? feed.id : 'search',
      query,
    ), () => _NovelChannel(query: query));
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
                  unawaited(ref.read(preferencesProvider).set('novel.discovery.source', id));
                },
              ),
              if (entry.source is SearchProvider &&
                  entry.supports(SourceCapability.search))
                TextButton.icon(
                  onPressed: () => context.push(
                    AppRoutes.searchFor(
                      MediaType.novel,
                      sourceId: sourceId,
                      query: query,
                      sourceOnly: true,
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('独立搜索页'),
                ),
            ],
          ),
        ),
        if (entry.source is SearchProvider &&
            entry.supports(SourceCapability.search))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: ValueKey('novel-source-query-$sourceId'),
              controller: editor,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '搜索${entry.descriptor.name}书名 / 作者',
                helperText: '提交后查询本站；清空后回到已选频道',
                suffixIcon: IconButton(
                  tooltip: '搜索本站',
                  icon: const Icon(Icons.search),
                  onPressed: () => setState(() =>
                      _applyQuery(sourceId, editor.text, channel)),
                ),
              ),
              onSubmitted: (value) => setState(() =>
                  _applyQuery(sourceId, value, channel)),
            ),
          ),
        if (query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                label: Text('本站搜索：$query'),
                onDeleted: () => setState(() {
                  _applyQuery(sourceId, '', channel);
                  editor.clear();
                }),
              ),
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
                    selected: query.isEmpty && candidate.id == feed.id,
                    onSelected: (_) {
                      setState(() {
                        _feeds[sourceId] = candidate.id;
                        _applyQuery(sourceId, '', channel);
                        editor.clear();
                      });
                      unawaited(ref.read(preferencesProvider).set('novel.discovery.feeds', Map<String, String>.of(_feeds)));
                    },
                  ),
                ),
            ],
          ),
        ),
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
              child: ListView.builder(
                key: PageStorageKey(
                  'novel-discovery-$sourceId-${feed.id}-$query',
                ),
                controller: channel.scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
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
                          Text(channel.error!, textAlign: TextAlign.center),
                          if (entry.source is AccountProvider)
                            Text(
                              (entry.source as AccountProvider).isLoggedIn
                                  ? '本站账号已登录；站点可能要求重新认证。'
                                  : '本站账号未登录；公开频道是否可访问由站点决定。',
                            ),
                          Wrap(
                            spacing: 12,
                            children: [
                              OutlinedButton(
                                onPressed: () => _load(entry, feed, channel),
                                child: const Text('重试'),
                              ),
                              if (channel.needsLogin)
                                FilledButton(
                                  onPressed: () =>
                                      _account(entry, feed, channel),
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
