import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/reader/manga_layout.dart';

void main() {
  test('宽图拆为有独立锚点的半页，最后半页之前不算整章结束', () {
    final layout = MangaLayout(
      2,
      doublePage: false,
      splitWide: true,
      rtl: true,
      geometry: {0: const Size(600, 900), 1: const Size(1800, 900)},
    );
    expect(layout.count, 3);
    expect(
      layout.screens.map((row) => (row.first.source, row.first.part)).toList(),
      [(0, 0), (1, 2), (1, 1)],
    );
    expect(layout.finishesChapter(layout.screenOf(1, 2)), isFalse);
    expect(layout.finishesChapter(layout.screenOf(1, 1)), isTrue);
    final reversed = MangaLayout(
      2,
      doublePage: false,
      splitWide: true,
      rtl: true,
      reverseSplit: true,
      geometry: {1: const Size(1800, 900)},
    );
    expect(reversed.firstAt(1).part, 1);
  });
  test('封面单页校正、横图整页和奇数尾页不破坏源图身份', () {
    final layout = MangaLayout(
      6,
      doublePage: true,
      soloCover: true,
      geometry: {3: const Size(1600, 900)},
    );
    expect(
      layout.screens.map((row) => row.map((v) => v.source).toList()).toList(),
      [
        [0],
        [1, 2],
        [3],
        [4, 5],
      ],
    );
    expect(layout.screenOf(2), 1);
    final rotated = MangaLayout(
      1,
      doublePage: false,
      rotateWide: true,
      rotateCounterclockwise: true,
      geometry: {0: const Size(1600, 900)},
    );
    expect(rotated.firstAt(0).turns, 3);
  });
  test('尺寸晚到或关闭拆分时按原图找到画面，不把虚拟页写成原图页', () {
    final unknown = MangaLayout(2, doublePage: false, splitWide: true);
    expect(unknown.screenOf(1, 2), 1);
    final known = MangaLayout(
      2,
      doublePage: false,
      splitWide: true,
      geometry: {1: const Size(1600, 900)},
    );
    expect(known.screenOf(1, 2), 2);
    final plain = MangaLayout(2, doublePage: false);
    expect(plain.firstAt(plain.screenOf(1, 2)).source, 1);
  });
}
