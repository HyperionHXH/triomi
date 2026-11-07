import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/manga_chapter_number.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_metadata.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/features/reader/manga_reading_order.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(platform, null);
  });

  test('Mihon default -1 titles reach the reader oldest first with specials intact', () async {
    const memo = '{"imageKey":"opaque","episode":6286738698187452081}';
    final raw = <Map<String, Object?>>[
      {'url': '/three', 'name': 'Work 14 第3话', 'chapterNumber': -1},
      {'url': '/extra', 'name': 'Work 14 番外', 'chapterNumber': -1},
      {'url': '/decimal', 'name': 'Work 14 Ch. 2.5', 'chapterNumber': -1},
      {'url': '/two', 'name': 'Work 14 ch.2', 'chapterNumber': -1},
      {'url': '/one', 'name': 'Work 14 第1话', 'chapterNumber': -1},
    ];
    final pageRequests = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(platform, (call) async {
      final args = call.arguments as Map;
      if (args['operation'] == 'chapters') {
        return {
          'ok': true,
          'chapters': [
            for (final row in raw)
              {...row, 'scanlator': 'Group', 'extensionMemo': memo},
          ],
        };
      }
      expect(args['operation'], 'pages');
      expect(args['manga'], isNull);
      pageRequests.add(Map<Object?, Object?>.from(args['chapter'] as Map));
      return {'ok': true, 'pages': <Object?>[]};
    });
    final source = _source();
    final item = MediaItem(
      sourceId: source.descriptor.id,
      remoteId: '/work',
      type: MediaType.manga,
      title: 'Work 14',
    );
    final chapters = await source.chapters(item);
    expect(chapters.map((chapter) => chapter.number), [3, -1, 2.5, 2, 1]);
    expect(chapters.map((chapter) => chapter.sortIndex), [0, 1, 2, 3, 4]);
    expect(
      chapters.map((chapter) => chapter.remoteId),
      raw.map((row) => row['url']),
    );
    expect(
      chapters.map((chapter) => chapter.title),
      raw.map((row) => row['name']),
    );
    final ordered = canonicalMangaReadingOrder(chapters);
    expect(ordered.map((chapter) => chapter.remoteId), [
      '/one',
      '/two',
      '/decimal',
      '/extra',
      '/three',
    ]);
    expect(mangaReadingIndexOf(ordered, chapters.last), 0);
    expect(mangaReadingIndexOf(ordered, chapters.first), 4);
    for (var index = 0; index < ordered.length; index++) {
      expect(ordered[index], same(chapters[chapters.length - 1 - index]));
      expect(ordered[index].sourceId, source.descriptor.id);
      expect(ordered[index].url, ordered[index].remoteId);
    }
    // Local recognition is presentation state, never a rewrite of SChapter.
    // Round-trip the metadata just as the database/cache does before requesting.
    for (final chapter in chapters) {
      await source.content(
        Chapter(
          sourceId: chapter.sourceId,
          remoteId: chapter.remoteId,
          title: chapter.title,
          url: chapter.url,
          number: chapter.number,
          sortIndex: chapter.sortIndex,
          sourceMetadata: SourceMetadata.fromJson(
            jsonDecode(jsonEncode(chapter.sourceMetadata!.toJson())),
          ),
        ),
      );
    }
    expect(pageRequests, hasLength(chapters.length));
    for (var index = 0; index < pageRequests.length; index++) {
      expect(pageRequests[index]['chapterNumber'], -1);
      expect(pageRequests[index]['url'], raw[index]['url']);
      expect(pageRequests[index]['name'], raw[index]['name']);
      expect(pageRequests[index]['extensionMemo'], memo);
      expect(pageRequests[index]['scanlator'], 'Group');
    }
  });

  test(
    'supplied chapter numbers and the native -2 sentinel win over names',
    () async {
      final requests = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(platform, (call) async {
        final args = call.arguments as Map;
        if (args['operation'] == 'chapters') {
          return {
            'ok': true,
            'chapters': [
              {'url': '/known', 'name': 'Chapter 99', 'chapterNumber': 4.25},
              {'url': '/zero', 'name': 'Chapter 88', 'chapterNumber': 0},
              {'url': '/special', 'name': 'Chapter 77', 'chapterNumber': -2},
              {'url': '/fraction', 'name': 'Chapter 66', 'chapterNumber': -0.5},
              {'url': '/negative', 'name': 'Chapter 55', 'chapterNumber': -3},
            ],
          };
        }
        requests.add(args['chapter'] as Map);
        return {'ok': true, 'pages': <Object?>[]};
      });
      final source = _source();
      final chapters = await source.chapters(
        MediaItem(
          sourceId: source.descriptor.id,
          remoteId: '/work',
          type: MediaType.manga,
          title: 'Work',
        ),
      );
      expect(chapters.map((chapter) => chapter.number), [
        4.25,
        0,
        -2,
        -0.5,
        -3,
      ]);
      for (final chapter in chapters) {
        await source.content(chapter);
      }
      expect(requests.map((request) => request['chapterNumber']), [
        4.25,
        0,
        -2,
        -0.5,
        -3,
      ]);
    },
  );

  test('shared Windows mapping keeps raw numbers without Android metadata', () async {
    final pageRequests = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(platform, (call) async {
      final args = call.arguments as Map;
      if (args['operation'] == 'chapters') {
        // Substitute only the host transport with the fake MethodChannel.
        // Mapping executes after this response under the Windows platform;
        // no JVM/bootstrap behavior is claimed by this mapping regression.
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        return {
          'ok': true,
          'chapters': [
            {'url': '/three', 'name': 'Chapter 3', 'chapterNumber': -1},
            {'url': '/two', 'name': 'Chapter 2', 'chapterNumber': -1},
            {'url': '/one', 'name': 'Chapter 1', 'chapterNumber': -1},
          ],
        };
      }
      pageRequests.add(args['chapter'] as Map);
      return {'ok': true, 'pages': <Object?>[]};
    });
    final source = _source();
    final chapters = await source.chapters(
      MediaItem(
        sourceId: source.descriptor.id,
        remoteId: '/work',
        type: MediaType.manga,
        title: 'Work',
      ),
    );
    expect(debugDefaultTargetPlatformOverride, TargetPlatform.windows);
    expect(chapters.map((chapter) => chapter.number), [3, 2, 1]);
    expect(
      canonicalMangaReadingOrder(chapters).map((chapter) => chapter.remoteId),
      ['/one', '/two', '/three'],
    );
    for (final chapter in chapters) {
      expect(chapter.sourceMetadata!.toJson(), isNot(contains('mihonAndroid')));
    }
    // Resume the fake host transport; raw portable metadata must be sufficient
    // on its own, independently of Android's extension memo snapshot.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final chapter in chapters) {
      await source.content(chapter);
    }
    await source.content(
      Chapter(
        sourceId: source.descriptor.id,
        remoteId: '/legacy',
        title: 'Legacy Chapter',
        number: 8,
      ),
    );
    expect(pageRequests.map((request) => request['chapterNumber']), [
      -1,
      -1,
      -1,
      8,
    ]);
  });

  test(
    'numeric work titles and wrapped specials cannot reverse a real catalog',
    () async {
      final fixtures = <(String, List<String>, List<double>, List<String>)>[
        (
          '86',
          ['Chapter 185', 'Chapter 186'],
          [185, 186],
          ['Chapter 185', 'Chapter 186'],
        ),
        (
          '86',
          ['Chapter 186', 'Chapter 185'],
          [186, 185],
          ['Chapter 185', 'Chapter 186'],
        ),
        (
          '86',
          ['Chapter 85.5', 'Chapter 86.5'],
          [85.5, 86.5],
          ['Chapter 85.5', 'Chapter 86.5'],
        ),
        (
          '86',
          ['Chapter 86,5', 'Chapter 85,5'],
          [86.5, 85.5],
          ['Chapter 85,5', 'Chapter 86,5'],
        ),
        (
          '5',
          ['Chapter 85.4', 'Chapter 86.5'],
          [85.4, 86.5],
          ['Chapter 85.4', 'Chapter 86.5'],
        ),
        (
          'Work',
          ['Chapter 1', 'Chapter 2', '[Extra] 1'],
          [1, 2, -1],
          ['Chapter 1', 'Chapter 2', '[Extra] 1'],
        ),
        ('Work', ['第1话', '第2话', '【番外】1'], [1, 2, -1], ['第1话', '第2话', '【番外】1']),
      ];
      for (final (workTitle, titles, numbers, expectedOrder) in fixtures) {
        messenger.setMockMethodCallHandler(
          platform,
          (call) async => {
            'ok': true,
            'chapters': [
              for (var index = 0; index < titles.length; index++)
                {
                  'url': '/chapter/$index',
                  'name': titles[index],
                  'chapterNumber': -1,
                },
            ],
          },
        );
        final source = _source();
        final chapters = await source.chapters(
          MediaItem(
            sourceId: source.descriptor.id,
            remoteId: '/work',
            type: MediaType.manga,
            title: workTitle,
          ),
        );
        expect(
          chapters.map((chapter) => chapter.number),
          numbers,
          reason: '$workTitle / $titles',
        );
        final ordered = canonicalMangaReadingOrder(chapters);
        expect(
          ordered.map((chapter) => chapter.title),
          expectedOrder,
          reason: '$workTitle / $titles',
        );
        for (final chapter in ordered) {
          expect(
            chapters.any((original) => identical(original, chapter)),
            isTrue,
          );
        }
      }
    },
  );

  test(
    'long internal whitespace preserves ordinary titles and numbered extras',
    () {
      final whitespace = ' \t' * 10000;
      for (final (title, expected) in <(String, double?)>[
        ('Chapter 4${whitespace}title', 4),
        ('4${whitespace}extra', 4.99),
        ('Work 4${whitespace}extra', 4.99),
        ('Unnumbered${whitespace}title', null),
      ]) {
        expect(
          recognizeMangaChapterNumber(mangaTitle: 'Work', chapterTitle: title),
          expected,
        );
      }
    },
  );

  test('recognition removes work numbers and volume tags without numbering unknown specials', () {
    final cases = <(String, String, double?)>[
      ('Ayame 14', 'Ayame 14 1 - The summer of 14', 1),
      ('86', 'Chapter 186', 186),
      ('86', '86 Chapter 186', 186),
      ('86', 'Chapter 86.5', 86.5),
      ('86', 'Chapter 86,5', 86.5),
      ('5', 'Chapter 86.5', 86.5),
      ('Bleach', 'Bleached 12', 12),
      ('Mokushiroku Alice', 'Mokushiroku Alice Vol.1 Ch.4: Title', 4),
      ('Mokushiroku Alice', 'Vol. 1 Ch. 4.1: Title', 4.1),
      ('Work', '第1话', 1),
      ('Work', '第2.5話', 2.5),
      ('Work', '第3回', 3),
      ('Work', 'ch.1', 1),
      ('Work', 'Chapter 1', 1),
      ('Work', 'Ch. 0', 0),
      ('Work', '011v002: Assembly Time', 11),
      ('Work', 'S3 - Chapter 20', 20),
      ('Work', '404 extra', 404.99),
      ('Work', '404 omake', 404.98),
      ('Work', '404 special', 404.97),
      ('Work', '19a', 19.1),
      ('Work', '024,005', 24.005),
      ('Work', '番外', null),
      ('Work', 'Special', null),
      ('Work', 'Extra 1', null),
      ('Work', '[Extra] 1', null),
      ('Work', '【番外】1', null),
      ('Work', '「Special」 1', null),
      ('Work', 'Vol. 2', null),
      ('Work 14', 'Work 14 番外', null),
    ];
    for (final (mangaTitle, chapterTitle, expected) in cases) {
      expect(
        recognizeMangaChapterNumber(
          mangaTitle: mangaTitle,
          chapterTitle: chapterTitle,
        ),
        expected,
        reason: '$mangaTitle / $chapterTitle',
      );
    }
    expect(
      recognizeMangaChapterNumber(
        mangaTitle: 'Work',
        chapterTitle: 'Special',
        providedNumber: -1,
      ),
      -1,
    );
    expect(
      recognizeMangaChapterNumber(
        mangaTitle: 'Work',
        chapterTitle: 'Chapter 7',
        providedNumber: -2,
      ),
      -2,
    );
  });
}

MihonSource _source() => MihonSource(
  packageName: 'org.example.order',
  hostSourceId: '42',
  name: 'Order',
  lang: 'zh',
  enabled: true,
  apkPath: '/private/apk',
  versionCode: 106000,
  signerSha256: null,
);
