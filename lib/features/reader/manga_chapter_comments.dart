import 'package:flutter/material.dart';

import '../../core/models/chapter.dart';

/// Native discussion text; no Android-generated image URLs or webpage execution.
class MangaChapterComments extends StatefulWidget {
  const MangaChapterComments({
    super.key,
    required this.comments,
    this.mode = 'merge',
  });

  final List<ChapterComment> comments;
  final String mode;

  @override
  State<MangaChapterComments> createState() => _MangaChapterCommentsState();
}

class _MangaChapterCommentsState extends State<MangaChapterComments> {
  static const _commentsPerPage = 20;
  int _page = 0;

  @override
  void didUpdateWidget(MangaChapterComments oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comments != widget.comments || oldWidget.mode != widget.mode) {
      _page = 0;
    }
  }

  Widget _comment(BuildContext context, int index) {
    final comment = widget.comments[index];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(comment.author, style: Theme.of(context).textTheme.titleSmall),
          if (comment.replyTo case final target? when target.isNotEmpty)
            Text('回复 $target', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          SelectableText(comment.text),
          const SizedBox(height: 12),
          const Divider(height: 1),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comments = widget.comments;
    final pages = (comments.length / _commentsPerPage).ceil();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: comments.isEmpty
            ? const Center(child: Text('暂无吐槽'))
            : widget.mode != 'separate'
            ? ListView.builder(
                itemCount: comments.length,
                itemBuilder: _comment,
              )
            : Column(
                children: [
                  Expanded(
                    child: PageView.builder(
                      key: ValueKey((comments, widget.mode)),
                      itemCount: pages,
                      onPageChanged: (page) => setState(() => _page = page),
                      itemBuilder: (context, page) {
                        final first = page * _commentsPerPage;
                        final remaining = comments.length - first;
                        return ListView.builder(
                          itemCount: remaining < _commentsPerPage
                              ? remaining
                              : _commentsPerPage,
                          itemBuilder: (context, index) =>
                              _comment(context, first + index),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('吐槽 ${_page + 1}/$pages'),
                  ),
                ],
              ),
      ),
    );
  }
}
