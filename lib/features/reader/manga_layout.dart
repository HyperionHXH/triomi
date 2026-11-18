import 'dart:ui';

/// A displayed region still belongs to exactly one original image.
class MangaLeaf {
  const MangaLeaf(this.source, {this.part = 0, this.turns = 0});
  final int source, part, turns;
}

/// Immutable display map rebuilt only when geometry or layout options change.
class MangaLayout {
  MangaLayout(
    int pages, {
    required bool doublePage,
    bool soloCover = false,
    bool splitWide = false,
    bool reverseSplit = false,
    bool rtl = false,
    bool rotateWide = false,
    bool rotateCounterclockwise = false,
    Map<int, Size> geometry = const {},
  }) {
    final leaves = <MangaLeaf>[];
    for (var page = 0; page < pages; page++) {
      final size = geometry[page];
      final wide = size != null && size.width > size.height;
      if (splitWide && wide) {
        final rightFirst = rtl != reverseSplit;
        leaves.add(MangaLeaf(page, part: rightFirst ? 2 : 1));
        leaves.add(MangaLeaf(page, part: rightFirst ? 1 : 2));
      } else {
        leaves.add(
          MangaLeaf(
            page,
            turns: wide && rotateWide
                ? rotateCounterclockwise
                      ? 3
                      : 1
                : 0,
          ),
        );
      }
    }
    final rows = <List<MangaLeaf>>[];
    for (var index = 0; index < leaves.length;) {
      final leaf = leaves[index];
      bool standalone(MangaLeaf v) {
        final size = geometry[v.source];
        return v.part == 0 &&
            v.turns == 0 &&
            size != null &&
            size.width > size.height;
      }

      if (!doublePage ||
          (soloCover && index == 0) ||
          standalone(leaf) ||
          index + 1 >= leaves.length ||
          standalone(leaves[index + 1])) {
        rows.add([leaf]);
        index++;
      } else {
        rows.add([leaf, leaves[index + 1]]);
        index += 2;
      }
    }
    screens = List.unmodifiable(rows);
  }
  late final List<List<MangaLeaf>> screens;
  int get count => screens.length;
  int screenOf(int source, [int part = 0]) {
    final exact = screens.indexWhere(
      (row) => row.any((v) => v.source == source && v.part == part),
    );
    if (exact >= 0) return exact;
    final found = screens.indexWhere(
      (row) => row.any((v) => v.source == source),
    );
    return found < 0 ? 0 : found;
  }

  MangaLeaf firstAt(int screen) =>
      screens[screen.clamp(0, screens.length - 1)].first;
  bool finishesChapter(int screen) => screen == count - 1;
}
