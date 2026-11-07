import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_repository.dart';

void main() {
  test('schema 13 upgrade preserves cached content and resume without inferring completion', () async {
    final directory = Directory.systemTemp.createTempSync(
      'triomi_chapter_state_v13_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}library.sqlite',
    );
    const manga = MediaItem(
      sourceId: 'manga',
      remoteId: 'same-work',
      type: MediaType.manga,
      title: 'Offline manga',
      url: 'https://manga.example/work',
    );
    const chapter = Chapter(
      sourceId: 'manga',
      remoteId: 'same-chapter',
      title: 'Cached chapter',
      url: 'https://manga.example/chapter',
      number: 7,
      sortIndex: 2,
    );
    const novel = MediaItem(
      sourceId: 'novel',
      remoteId: 'same-work',
      type: MediaType.novel,
      title: 'Offline novel',
    );
    const novelChapter = Chapter(
      sourceId: 'novel',
      remoteId: 'same-chapter',
      title: 'Novel chapter',
      number: 3,
    );

    final prepare = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final library = LibraryRepository(prepare);
      for (final (item, chapters, position) in [
        (manga, [chapter], 4.0),
        (novel, [novelChapter], 12.0),
      ]) {
        await library.addToLibrary(item);
        await library.saveChapters(
          itemSourceId: item.sourceId,
          itemRemoteId: item.remoteId,
          chapters: chapters,
        );
        await library.recordHistory(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapter: chapters.single,
          position: position,
        );
        await library.updateProgress(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapterNumber: chapters.single.number!,
        );
      }
    } finally {
      await prepare.close();
    }

    // v14 only adds manga_chapter_states. Removing that table reconstructs
    // the exact v13 table set, while all old content stays in the real file.
    final old = sqlite3.sqlite3.open(file.path);
    try {
      old.execute('DROP TABLE manga_chapter_states');
      old.execute('PRAGMA user_version = 13');
      old.execute(
        'UPDATE chapters SET content_json = ? WHERE source_id = ? AND remote_id = ?',
        [
          jsonEncode({
            'images': [
              'https://images.example/1.jpg',
              'https://images.example/2.jpg',
            ],
          }),
          'manga',
          'same-chapter',
        ],
      );
      old.execute(
        'UPDATE chapters SET content_json = ? WHERE source_id = ? AND remote_id = ?',
        [
          jsonEncode({
            'html': '<p>Preserved novel text</p>',
            'font': 'offline-font',
            'fontData': 'AAECAw==',
          }),
          'novel',
          'same-chapter',
        ],
      );
      expect(old.select('PRAGMA user_version').single['user_version'], 13);
      expect(
        old.select(
          "SELECT name FROM sqlite_master WHERE name = 'manga_chapter_states'",
        ),
        isEmpty,
      );
    } finally {
      old.close();
    }

    var upgraded = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final library = LibraryRepository(upgraded);
      final books = await library.listLibrary();
      expect(
        {for (final book in books) book.item.sourceId: book.entry.progress},
        {'manga': 7.0, 'novel': 3.0},
      );
      expect((await library.itemByKey('manga', 'same-work'))!.url, manga.url);
      final cachedManga = (await library.loadChapters(
        'manga',
        'same-work',
      )).single;
      expect(cachedManga.title, chapter.title);
      expect(cachedManga.url, chapter.url);
      expect(cachedManga.number, 7);
      expect(cachedManga.sortIndex, 2);
      expect(cachedManga.content!.images, [
        'https://images.example/1.jpg',
        'https://images.example/2.jpg',
      ]);
      final cachedNovel = (await library.loadChapters(
        'novel',
        'same-work',
      )).single;
      expect(cachedNovel.content!.html, '<p>Preserved novel text</p>');
      expect(cachedNovel.content!.fontFamily, 'offline-font');
      expect(cachedNovel.content!.fontData, 'AAECAw==');
      expect(
        await library.chapterPositionOf('manga', 'same-work', 'same-chapter'),
        4,
      );
      expect(
        await library.chapterPositionOf('novel', 'same-work', 'same-chapter'),
        12,
      );
      expect(
        await library.watchMangaChapterStates('manga', 'same-work').first,
        isEmpty,
        reason: 'Legacy visits and shelf progress do not prove completion',
      );

      await library.recordMangaChapterPageCount(
        sourceId: 'manga',
        itemRemoteId: 'same-work',
        chapter: cachedManga,
        totalPages: 2,
      );
      await library.setChapterBookmarked(
        sourceId: 'manga',
        itemRemoteId: 'same-work',
        chapters: [cachedManga],
        bookmarked: true,
      );
      await library.setChapterRead(
        sourceId: 'manga',
        itemRemoteId: 'same-work',
        chapters: [cachedManga],
        read: true,
      );
    } finally {
      await upgraded.close();
    }

    // A second open exercises the committed version and the new persistent
    // consumer API, rather than only asserting that CREATE TABLE succeeded.
    upgraded = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final library = LibraryRepository(upgraded);
      final state =
          (await library.watchMangaChapterStates('manga', 'same-work').first)
              .single;
      expect(
        [
          state.chapterSourceId,
          state.chapterRemoteId,
          state.isRead,
          state.bookmarked,
          state.totalPages,
        ],
        ['manga', 'same-chapter', true, true, 2],
      );
      expect(
        (await library.loadChapters(
          'manga',
          'same-work',
        )).single.content!.images,
        ['https://images.example/1.jpg', 'https://images.example/2.jpg'],
      );
      expect(
        (await library.loadChapters('novel', 'same-work')).single.content!.html,
        '<p>Preserved novel text</p>',
      );
      expect(
        await library.chapterPositionOf('manga', 'same-work', 'same-chapter'),
        4,
      );
      expect(
        await library.chapterPositionOf('novel', 'same-work', 'same-chapter'),
        12,
      );
    } finally {
      await upgraded.close();
    }
    final reopened = sqlite3.sqlite3.open(file.path);
    try {
      expect(reopened.select('PRAGMA user_version').single['user_version'], 14);
    } finally {
      reopened.close();
    }
  });
}
