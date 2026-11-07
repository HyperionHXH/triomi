import '../../core/models/chapter.dart';
import '../../core/models/manga_chapter_number.dart';

/// Reading order is independent of a catalog's ascending/descending display.
/// Keep the original chapters (including special releases) and their identities.
/// Confirmed merged directories already provide their cross-work order; pass
/// [preserveOrder] to retain it, including when all works share one source.
List<Chapter> canonicalMangaReadingOrder(
  Iterable<Chapter> chapters, {
  bool preserveOrder = false,
  String mangaTitle = '',
}) {
  var ordered = chapters.toList();
  if (preserveOrder || ordered.length < 2) return ordered;
  final positions = <Chapter, int>{
    for (var index = 0; index < ordered.length; index++) ordered[index]: index,
  };
  if (ordered.every((chapter) => chapter.sourceId == ordered.first.sourceId)) {
    ordered.sort((a, b) {
      final sourceOrder = a.sortIndex.compareTo(b.sortIndex);
      return sourceOrder != 0
          ? sourceOrder
          : positions[a]!.compareTo(positions[b]!);
    });
  }
  double? firstNumber, lastNumber;
  for (final chapter in ordered) {
    final number = recognizeMangaChapterNumber(
      mangaTitle: mangaTitle,
      chapterTitle: chapter.title,
      providedNumber: chapter.number,
    );
    if (number != null && number.isFinite && number >= 0) {
      firstNumber ??= number;
      lastNumber = number;
    }
  }
  if (firstNumber != null && lastNumber != null && firstNumber > lastNumber) {
    ordered = ordered.reversed.toList();
  }
  // Source order anchors nonnumeric releases and duplicate numbers. Only
  // reverse its direction: sorting numbers detaches specials from neighbours.
  // Source-local sortIndex cannot order chapters across merged works, even
  // when they share a source. Their caller must preserve the supplied order.
  return ordered;
}

int mangaReadingIndexOf(List<Chapter> chapters, Chapter chapter) =>
    chapters.indexWhere(
      (candidate) =>
          candidate.sourceId == chapter.sourceId &&
          candidate.remoteId == chapter.remoteId,
    );
