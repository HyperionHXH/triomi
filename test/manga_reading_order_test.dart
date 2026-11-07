import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/features/reader/manga_reading_order.dart';

Chapter chapter(String id, int order, {double? number, String source = 's'}) =>
    Chapter(
      sourceId: source,
      remoteId: id,
      title: id,
      sortIndex: order,
      number: number,
    );

void main() {
  test('descending source catalog 3,2,1 reads 1 then 2', () {
    final input = [
      chapter('three', 0, number: 3),
      chapter('two', 1, number: 2),
      chapter('one', 2, number: 1),
    ];
    final ordered = canonicalMangaReadingOrder(input);
    expect(ordered.map((c) => c.remoteId), ['one', 'two', 'three']);
    expect(mangaReadingIndexOf(ordered, input.last), 0);
    expect(
      input.first.remoteId,
      'three',
      reason: 'Do not mutate display order',
    );
  });

  test('cached native unknown numbers use recognized titles without changing source state', () {
    final input = [
      const Chapter(
        sourceId: 'mihon:site',
        remoteId: 'three',
        title: 'Manga 86 第3话',
        number: -1,
        sortIndex: 0,
      ),
      const Chapter(
        sourceId: 'mihon:site',
        remoteId: 'special',
        title: 'Extra',
        number: -1,
        sortIndex: 1,
      ),
      const Chapter(
        sourceId: 'mihon:site',
        remoteId: 'two',
        title: 'Manga 86 第2话',
        number: -1,
        sortIndex: 2,
      ),
      const Chapter(
        sourceId: 'mihon:site',
        remoteId: 'one',
        title: 'Manga 86 第1话',
        number: -1,
        sortIndex: 3,
      ),
    ];
    final ordered = canonicalMangaReadingOrder(input, mangaTitle: 'Manga 86');
    expect(ordered.map((c) => c.remoteId), ['one', 'two', 'special', 'three']);
    expect(ordered.map((c) => c.number), everyElement(-1));
    expect(identical(ordered.first, input.last), isTrue);
  });

  test('descending special chapter retains its source-relative anchor', () {
    final ordered = canonicalMangaReadingOrder([
      chapter('three', 0, number: 3),
      chapter('two', 1, number: 2),
      chapter('special', 2),
      chapter('one', 3, number: 1),
    ]);
    expect(ordered.map((c) => c.remoteId), ['one', 'special', 'two', 'three']);
  });

  test('unknown-number chapters keep source order without title guessing', () {
    final input = [chapter('Volume 200', 0), chapter('Extra 1', 1)];
    expect(canonicalMangaReadingOrder(input), input);
  });

  test(
    'mixed owners retain equal-number releases and qualified identities',
    () {
      final a = chapter('same', 9, number: 1, source: 'a');
      final b = chapter('same', 0, number: 1, source: 'b');
      final ordered = canonicalMangaReadingOrder([a, b]);
      expect(ordered, [a, b]);
      expect(mangaReadingIndexOf(ordered, b), 1);
    },
  );

  test('confirmed same-source merged works preserve the supplied order', () {
    final input = [
      chapter('work-a/one', 0, number: 1),
      chapter('work-a/two', 1, number: 2),
      chapter('work-b/three', 0, number: 3),
      chapter('work-b/four', 1, number: 4),
    ];
    expect(canonicalMangaReadingOrder(input, preserveOrder: true), input);
    expect(
      canonicalMangaReadingOrder(input.reversed, preserveOrder: true),
      input.reversed.toList(),
      reason: 'Confirmed order must not be sorted or direction-normalized',
    );
  });

  test('display reversal cannot change unique sortIndex reading order', () {
    final input = [chapter('one', 0, number: 1), chapter('two', 1, number: 2)];
    expect(canonicalMangaReadingOrder(input.reversed), input);
  });
}
