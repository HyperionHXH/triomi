import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_retry_policy.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final message in [
    '未知網路錯誤 (HTTP 210 : 触发拷贝漫画防盗版机制，请尝试开启VPN/切换节点/更换域名 (现已支持热辣漫画))',
    'HTTP 210 : 觸發拷貝漫畫防盜版機制',
  ]) {
    test(
      'plugin access restriction is preserved and never retried: $message',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {
            'ok': false,
            'errorCode': 'source_request_failed',
            'error': message,
          },
        );
        final source = _source();
        try {
          await source.search('test');
          fail('The source must report the restriction');
        } on SourceException catch (error) {
          expect(error.type, SourceErrorType.permission);
          expect(error.message, message);
          expect(
            error.statusCode,
            isNull,
            reason: 'A plugin message must not invent HTTP response metadata',
          );
          expect(DownloadRetryPolicy.transient(error), isFalse);
        }
      },
    );
  }

  test(
    'ordinary plugin transport failure remains eligible for bounded retry',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'ok': false, 'error': '網路錯誤 (Socket closed)'},
      );
      try {
        await _source().search('test');
        fail('The source must report the transport failure');
      } on SourceException catch (error) {
        expect(error.type, SourceErrorType.network);
        expect(DownloadRetryPolicy.transient(error), isTrue);
      }
    },
  );

  test(
    'background plugin download records restriction without a retry',
    () async {
      const message = 'HTTP 210 : 触发拷贝漫画防盗版机制';
      var hostCalls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        hostCalls++;
        return {'ok': false, 'error': message};
      });
      final db = openTestDatabase();
      try {
        final source = _source();
        final library = LibraryRepository(db);
        final repository = DownloadRepository(db);
        final item = MediaItem(
          sourceId: source.descriptor.id,
          remoteId: '/work',
          type: MediaType.manga,
          title: 'Work',
        );
        final chapter = Chapter(
          sourceId: item.sourceId,
          remoteId: '/chapter',
          title: 'Chapter',
          url: '/chapter',
        );
        await library.cacheItem(item);
        await library.saveChapters(
          itemSourceId: item.sourceId,
          itemRemoteId: item.remoteId,
          chapters: [chapter],
        );
        final id = await repository.enqueue(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapter: chapter,
        );
        final service = DownloadService(
          repository: repository,
          http: FakeHttpClient(
            (_) async => throw StateError('no image expected'),
          ),
          preferences: memoryPreferences(),
        );
        await expectLater(
          service.run(
            row: (await repository.rowById(id))!,
            provider: source,
            scheduleTransientRetry: true,
          ),
          throwsA(isA<SourceException>()),
        );
        final row = (await repository.rowById(id))!;
        expect(row.status, 'failed');
        expect(row.retryCount, 0);
        expect(row.retryAt, isNull);
        expect(row.errorMessage, contains(message));
        expect(hostCalls, 1);
      } finally {
        await db.close();
      }
    },
  );
}

MihonSource _source() => MihonSource(
  packageName: 'eu.kanade.tachiyomi.extension.zh.copymanga',
  hostSourceId: '6696312508930833206',
  name: 'CopyManga',
  lang: 'zh',
  enabled: true,
  apkPath: '/private/copy.apk',
  versionCode: 85,
  signerSha256: null,
);
