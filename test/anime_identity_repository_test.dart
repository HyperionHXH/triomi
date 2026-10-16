import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

void main() {
  const subject = MediaItem(
    sourceId: 'bangumi-anime',
    remoteId: 'season-1',
    type: MediaType.anime,
    title: '同名动画',
  );
  const otherSeason = MediaItem(
    sourceId: 'bangumi-anime',
    remoteId: 'season-2',
    type: MediaType.anime,
    title: '同名动画',
  );
  const siteA = MediaItem(
    sourceId: 'site-a',
    remoteId: '1',
    type: MediaType.anime,
    title: '第一季',
  );
  const siteB = MediaItem(
    sourceId: 'site-b',
    remoteId: '1',
    type: MediaType.anime,
    title: '第一季别名',
  );
  const ep = Chapter(
    sourceId: 'site-a',
    remoteId: 'list4/ep1',
    title: '第01集',
    volumeTitle: '列表4',
  );

  test('人工映射保持季身份；切站不套时间；文件重开仍恢复最后列表剧集', () async {
    final dir = Directory.systemTemp.createTempSync('triomi-anime-identity-');
    final path = File('${dir.path}/db.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(path));
    try {
      var repo = AnimeIdentityRepository(db);
      await repo.confirm(subject, siteA);
      await repo.saveAlias(subject, 'site-b', '本站别名');
      await repo.confirm(subject, siteB);
      expect((await repo.subjectFor(siteA))!.remoteId, subject.remoteId);
      await expectLater(repo.confirm(otherSeason, siteA), throwsStateError);
      await expectLater(repo.recordSelection(siteA, ep), throwsStateError);
      expect(await repo.lastSelection(subject), isNull);
      await LibraryRepository(db).saveChapters(
        itemSourceId: siteA.sourceId,
        itemRemoteId: siteA.remoteId,
        chapters: [ep],
      );
      await repo.recordSelection(siteA, ep);
      expect(await repo.shouldResetPosition(siteB), isTrue);
      expect(await repo.shouldResetPosition(siteA), isFalse);
      expect(
        (await repo.links(subject))
            .firstWhere((l) => l.sourceId == 'site-b')
            .alias,
        '本站别名',
      );
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      final forgotten = Completer<MediaItem>();
      final subscription = container.listen(animeSubjectProvider(siteB), (
        _,
        next,
      ) {
        if (next.hasValue &&
            next.value!.remoteId == siteB.remoteId &&
            !forgotten.isCompleted) {
          forgotten.complete(next.value);
        }
      }, fireImmediately: true);
      expect(
        (await container.read(animeSubjectProvider(siteB).future)).remoteId,
        subject.remoteId,
      );
      await repo.forget(subject, siteB.sourceId);
      expect(
        (await forgotten.future.timeout(const Duration(seconds: 3))).remoteId,
        siteB.remoteId,
      );
      subscription.close();
      container.dispose();
      await repo.confirm(subject, siteB);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(path));
      repo = AnimeIdentityRepository(db);
      final selection = await repo.lastSelection(subject);
      expect(selection!.item.remoteId, siteA.remoteId);
      expect(selection.chapter!.remoteId, ep.remoteId);
      expect(selection.chapter!.volumeTitle, '列表4');
      final library = LibraryRepository(db);
      await library.addAnimeFollow((await repo.subjectFor(siteB))!);
      expect(
        (await library.listAnimeFollows()).single.item.remoteId,
        subject.remoteId,
      );
      expect(await repo.lastSelection(otherSeason), isNull);
    } finally {
      await db.close();
      dir.deleteSync(recursive: true);
    }
  });

  test('备份恢复确认映射和列表，新记录不被旧备份覆盖', () async {
    final first = AppDatabase.forTesting(NativeDatabase.memory());
    final second = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(first.close);
    addTearDown(second.close);
    final one = AnimeIdentityRepository(first);
    await one.confirm(subject, siteA);
    await one.saveAlias(subject, siteA.sourceId, '第一季站点名');
    await LibraryRepository(first).saveChapters(
      itemSourceId: siteA.sourceId,
      itemRemoteId: siteA.remoteId,
      chapters: [ep],
    );
    await one.recordSelection(siteA, ep);
    BackupService backup(AppDatabase db) => BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    );
    final bytes = (await backup(first).exportToBytes(includeCovers: false))
        .bytes;
    await backup(second).importFromBytes(bytes);
    final two = AnimeIdentityRepository(second);
    expect((await two.subjectFor(siteA))!.remoteId, subject.remoteId);
    expect((await two.lastSelection(subject))!.chapter!.remoteId, ep.remoteId);
    await two.saveAlias(subject, siteA.sourceId, '本机较新别名');
    await backup(second).importFromBytes(bytes);
    expect((await two.links(subject)).single.alias, '本机较新别名');
    await two.forget(subject, siteA.sourceId);
    expect(await two.subjectFor(siteA), isNull);
    expect(
      (await LibraryRepository(
        second,
      ).loadChapters(siteA.sourceId, siteA.remoteId)).single.remoteId,
      ep.remoteId,
    );
    await two.confirm(otherSeason, siteA);
    await expectLater(
      backup(second).importFromBytes(bytes),
      throwsA(isA<Exception>()),
    );
    expect((await two.subjectFor(siteA))!.remoteId, otherSeason.remoteId);
    expect(await two.links(subject), isEmpty);
  });
}
