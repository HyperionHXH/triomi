import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/features/novel/export/epub_exporter.dart';
import 'package:triomi/features/novel/export/novel_export_service.dart';
import 'package:triomi/features/novel/reader/chapter_font.dart';

import 'fixtures/fake_http_client.dart';

class _FontSource implements ContentProvider {
  _FontSource(this.body);
  final ChapterContent body;
  final requested = <String>[];
  bool failOnRequest = false;
  @override
  bool get isReady => true;
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'font-source',
    name: 'Font',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    requested.add(chapter.remoteId);
    if (failOnRequest) throw StateError('Network unavailable');
    return body;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('LNS official file permission blocks both exports before reading cache/network', () async {
    const restricted = MediaItem(
      sourceId: 'light-novel-shelf',
      remoteId: '1',
      type: MediaType.novel,
      title: 'Book',
    );
    final source = _FontSource(const ChapterContent(text: 'cached'));
    final http = FakeHttpClient((_) async => throw StateError('no network'));
    final permission = isA<SourceException>().having(
      (e) => e.type,
      'type',
      SourceErrorType.permission,
    );
    await expectLater(
      NovelExportService.exportEpub(
        item: restricted,
        chapters: const [],
        source: source,
        http: http,
        onProgress: (_, _) {},
      ),
      throwsA(permission),
    );
    await expectLater(
      NovelExportService.exportTxt(
        item: restricted,
        chapters: const [],
        source: source,
        onProgress: (_, _) {},
      ),
      throwsA(permission),
    );
    expect(source.requested, isEmpty);
    expect(http.requests, isEmpty);
  });
  final font = Uint8List.fromList([0, 1, 0, 0, 0, 0, 0, 0]);
  final body = ChapterContent(
    html: '<p>\uE001\uE002</p>',
    fontFamily: 'required',
    fontData: base64Encode(font),
  );
  const item = MediaItem(
    sourceId: 'font-source',
    remoteId: 'book',
    type: MediaType.novel,
    title: 'Font book',
  );
  const chapters = [
    Chapter(sourceId: 'font-source', remoteId: 'one', title: 'One'),
    Chapter(sourceId: 'font-source', remoteId: 'two', title: 'Two'),
    Chapter(
      sourceId: 'font-source',
      remoteId: 'locked',
      title: 'Locked',
      locked: true,
    ),
  ];
  test('download/backup JSON carries font bytes and rejects bad font data', () {
    final restored = ChapterContent.fromJson(
      jsonDecode(jsonEncode(body.toJson())),
    )!;
    expect(ChapterFont.decode(restored.fontData!), font);
    expect(
      () =>
          ChapterFont.decode(base64Encode(utf8.encode('<html>blocked</html>'))),
      throwsStateError,
    );
    expect(() => ChapterFont.decode('!invalid!'), throwsFormatException);
  });
  test(
    'EPUB embeds one font, declares it and styles only chapter prose',
    () async {
      final source = _FontSource(body);
      Uint8List? written;
      final result = await NovelExportService.exportEpub(
        item: item,
        chapters: chapters,
        source: source,
        http: FakeHttpClient(
          (_) async => throw StateError('No image request expected'),
        ),
        onProgress: (_, _) {},
        directoryUri: 'authorized',
        writeToTree: (_, _, bytes) async {
          written = Uint8List.fromList(bytes);
          return 'content://epub';
        },
      );
      expect(result.exportedChapters, 2);
      expect(result.skippedChapters, 1);
      expect(source.requested, ['one', 'two']);
      final archive = EpubExporter.decode(written!);
      final fonts = archive.files.where(
        (f) => f.name.startsWith('OEBPS/fonts/'),
      );
      expect(fonts, hasLength(1));
      expect(fonts.single.content, font);
      String text(String name) =>
          utf8.decode(archive.findFile(name)!.content as List<int>);
      final css = text('OEBPS/styles.css');
      expect(css, contains('@font-face'));
      expect(css, contains(fonts.single.name.substring('OEBPS/'.length)));
      expect(text('OEBPS/content.opf'), contains('media-type="font/ttf"'));
      expect(
        text('OEBPS/chapter-0001.xhtml'),
        contains('<div style="font-family: chapter-'),
      );
      expect(text('OEBPS/nav.xhtml'), isNot(contains('Locked')));
    },
  );
  test(
    'TXT refuses substituted glyphs before writing an unreadable artifact',
    () async {
      var wrote = false;
      await expectLater(
        NovelExportService.exportTxt(
          item: item,
          chapters: chapters,
          source: _FontSource(body),
          onProgress: (_, _) {},
          directoryUri: 'authorized',
          writeToTree: (_, _, _) async {
            wrote = true;
            return 'content://txt';
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('EPUB'),
          ),
        ),
      );
      expect(wrote, false);
    },
  );
  test('downloaded font chapters export offline without contacting source or locks', () async {
    final source = _FontSource(body)..failOnRequest = true;
    final cacheRequests = <String>[];
    final result = await NovelExportService.exportEpub(
      item: item,
      chapters: chapters,
      source: source,
      http: FakeHttpClient(
        (_) async => throw StateError('No network expected'),
      ),
      localContent: (chapter) async {
        cacheRequests.add(chapter.remoteId);
        return body;
      },
      onProgress: (_, _) {},
      directoryUri: 'authorized',
      writeToTree: (_, _, _) async => 'content://epub',
    );
    expect(result.exportedChapters, 2);
    expect(result.skippedChapters, 1);
    expect(cacheRequests, ['one', 'two']);
    expect(source.requested, isEmpty);
  });
  test(
    'uncached chapters fall back to source while cached plain TXT stays local',
    () async {
      final source = _FontSource(const ChapterContent(text: 'online'));
      List<int>? bytes;
      await NovelExportService.exportTxt(
        item: item,
        chapters: chapters,
        source: source,
        localContent: (chapter) async => chapter.remoteId == 'one'
            ? const ChapterContent(text: 'offline')
            : null,
        onProgress: (_, _) {},
        directoryUri: 'authorized',
        writeToTree: (_, _, data) async {
          bytes = data;
          return 'content://txt';
        },
      );
      expect(source.requested, ['two']);
      expect(utf8.decode(bytes!), contains('offline'));
      expect(utf8.decode(bytes!), contains('online'));
      expect(utf8.decode(bytes!), isNot(contains('Locked')));
    },
  );
}
