import 'package:flutter/material.dart';

bool approachingScrollEnd(ScrollNotification notice) =>
    notice.depth == 0 &&
    notice.metrics.axis == Axis.vertical &&
    notice.metrics.extentAfter < 400 &&
    (switch (notice) {
      ScrollUpdateNotification(:final scrollDelta) => (scrollDelta ?? 0) > 0,
      OverscrollNotification(:final overscroll) => overscroll > 0,
      _ => false,
    });

/// Request the next page on forward movement, including short lists. Ignore
/// nested carousels and the reverse gesture used for pull-to-refresh.
class LoadMoreOnScroll extends StatelessWidget {
  const LoadMoreOnScroll({super.key, this.onLoadMore, required this.child});

  final VoidCallback? onLoadMore;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (notice) {
          if (approachingScrollEnd(notice)) onLoadMore?.call();
          return false;
        },
        child: child,
      );
}

class PageTail extends StatelessWidget {
  const PageTail({super.key, required this.loading, required this.ended});

  final bool loading;
  final bool ended;

  @override
  Widget build(BuildContext context) {
    if (!loading && !ended) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('已经到底了', style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}
