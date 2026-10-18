part of 'detail_page.dart';

class _AnimeHero extends StatelessWidget {
  const _AnimeHero({required this.item, required this.onPlay});
  final MediaItem item;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.12,
                child: MediaCover(url: item.coverUrl),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 88,
                          height: 132,
                          child: MediaCover(url: item.coverUrl),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('番剧', style: theme.textTheme.labelMedium),
                            const SizedBox(height: 8),
                            Text(
                              item.title,
                              style: theme.textTheme.headlineSmall,
                            ),
                            if (item.status?.isNotEmpty == true)
                              Text(item.status!),
                            if (item.rating != null)
                              Text(
                                '★ ${item.rating!.toStringAsFixed(1)}${item.sourceId == 'bangumi-anime' ? ' · Bangumi' : ''}',
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('开始 / 继续观看'),
                      ),
                      AnimeCollectionButton(item: item),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MangaHeader extends StatelessWidget {
  const _MangaHeader({
    required this.data,
    required this.historyRevision,
    required this.onReturned,
  });
  final _DetailData data;
  final int historyRevision;
  final VoidCallback onReturned;

  @override
  Widget build(BuildContext context) {
    final item = data.item!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: AppRadius.cardRadius,
                child: SizedBox(
                  width: 112,
                  height: 168,
                  child: MediaCover(url: item.coverUrl),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: theme.textTheme.titleLarge),
                    if (item.author?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Text(item.author!, style: theme.textTheme.bodyMedium),
                    ],
                    if (item.status?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Text(item.status!, style: theme.textTheme.bodySmall),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      data.sourceName.isEmpty ? item.sourceId : data.sourceName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: context.palette.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ReadContinueButton(
                data: data,
                historyRevision: historyRevision,
                onReturned: onReturned,
              ),
              _MangaCollectionButton(item: item),
            ],
          ),
          if (item.description?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            _ExpandableSynopsis(text: item.description!),
          ],
          _DetailTags(item: item),
        ],
      ),
    );
  }
}

class _NovelBookHeader extends StatelessWidget {
  const _NovelBookHeader({
    required this.data,
    required this.historyRevision,
    required this.onReturned,
  });
  final _DetailData data;
  final int historyRevision;
  final VoidCallback onReturned;

  @override
  Widget build(BuildContext context) {
    final item = data.item!;
    final theme = Theme.of(context);
    final volumes = <String>{
      for (final chapter in data.chapters)
        if (chapter.volumeTitle?.trim().isNotEmpty == true)
          chapter.volumeTitle!.trim(),
    }.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 96,
                  height: 144,
                  child: MediaCover(url: item.coverUrl),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: theme.textTheme.titleLarge),
                    if (item.author?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Text(
                        item.author!,
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '来源 · ${data.sourceName.isEmpty ? item.sourceId : data.sourceName}',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (item.status?.isNotEmpty == true)
                      Text(item.status!, style: theme.textTheme.bodySmall),
                    if (data.chapters.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${volumes == 0 ? '' : '$volumes 卷 · '}${data.chapters.length} 章',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _ReadContinueButton(
            data: data,
            historyRevision: historyRevision,
            onReturned: onReturned,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: NovelCollectionButton(item: item),
          ),
          _DetailTags(item: item),
          if (item.description?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('内容简介', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _ExpandableSynopsis(text: item.description!),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReadContinueButton extends ConsumerStatefulWidget {
  const _ReadContinueButton({
    required this.data,
    required this.historyRevision,
    required this.onReturned,
  });
  final _DetailData data;
  final int historyRevision;
  final VoidCallback onReturned;

  @override
  ConsumerState<_ReadContinueButton> createState() =>
      _ReadContinueButtonState();
}

class _ReadContinueButtonState extends ConsumerState<_ReadContinueButton> {
  late Future<HistoryView?> _history;

  void _loadHistory() {
    final item = widget.data.item!;
    _history = ref
        .read(libraryRepositoryProvider)
        .lastReadOf(item.sourceId, item.remoteId);
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void didUpdateWidget(covariant _ReadContinueButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.item?.sourceId != widget.data.item?.sourceId ||
        oldWidget.data.item?.remoteId != widget.data.item?.remoteId ||
        oldWidget.historyRevision != widget.historyRevision) {
      _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<HistoryView?>(
    future: _history,
    builder: (context, snapshot) {
      final data = widget.data;
      final item = data.item!;
      var index = data.chapters.indexWhere(
        (chapter) =>
            chapter.remoteId == snapshot.data?.chapterRemoteId &&
            chapter.sourceId == item.sourceId &&
            (!chapter.locked || item.type == MediaType.novel),
      );
      final continuing = index >= 0;
      if (index < 0) {
        index = data.chapters.indexWhere(
          (chapter) =>
              chapter.sourceId == item.sourceId &&
              (!chapter.locked || item.type == MediaType.novel),
        );
      }
      final target = index;
      return FilledButton.icon(
        key: const ValueKey('detail-continue-read'),
        icon: const Icon(Icons.menu_book_outlined),
        label: Text(target < 0 ? '暂无可读章节' : '${continuing ? '继续' : '开始'}阅读'),
        onPressed: target < 0 || !data.supportsContent
            ? null
            : () async {
                await _ChapterSection(
                  item: item,
                  chapters: data.chapters,
                  supportsContent: true,
                )._openChapter(context, target);
                if (mounted) widget.onReturned();
              },
      );
    },
  );
}

class _DetailTags extends StatelessWidget {
  const _DetailTags({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) => item.tags.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final tag in item.tags)
                ActionChip(
                  label: Text(tag),
                  onPressed: () => SearchPage.open(
                    context,
                    type: item.type,
                    sourceId: item.sourceId,
                    sourceOnly: true,
                    tags: [tag],
                  ),
                ),
            ],
          ),
        );
}

class _ExpandableSynopsis extends StatefulWidget {
  const _ExpandableSynopsis({required this.text});
  final String text;

  @override
  State<_ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<_ExpandableSynopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.text,
        maxLines: _expanded ? null : 3,
        overflow: _expanded ? null : TextOverflow.ellipsis,
      ),
      TextButton(
        onPressed: () => setState(() => _expanded = !_expanded),
        child: Text(_expanded ? '收起简介' : '展开简介'),
      ),
    ],
  );
}

class _DetailLoadFailure extends StatelessWidget {
  const _DetailLoadFailure({
    required this.title,
    required this.error,
    required this.retryLabel,
    required this.onRetry,
  });

  final String title;
  final String error;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(retryLabel),
              ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('错误详情'),
            children: [SelectableText(SourceException.sanitizeMessage(error))],
          ),
        ],
      ),
    ),
  );
}
