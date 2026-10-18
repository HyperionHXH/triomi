import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/manga_metadata_override.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/core/source/mihon_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'Mihon request methods degrade when native host is unavailable',
    () async {
      final inspect = await platformChannel.inspectMihonExtension(
        apkPath: '/private/plugin.apk',
        packageName: 'eu.kanade.tachiyomi.extension.all.mangadex',
        versionCode: 106000,
      );
      expect(inspect, <String, Object?>{
        'ok': false,
        'error': '当前平台没有 Mihon 宿主',
      });
      expect(await platformChannel.setMihonEnabled('pkg', true), isFalse);
      expect(
        await platformChannel.openMihonSession(
          packageName: 'pkg',
          sourceId: '1',
        ),
        <String, Object?>{'ok': false, 'error': '当前平台没有 Mihon 宿主'},
      );
      expect(
        await platformChannel.mihonRequest(
          packageName: 'pkg',
          operation: 'search',
        ),
        <String, Object?>{'ok': false, 'error': '当前平台没有 Mihon 宿主'},
      );
    },
  );

  test(
    'Mihon request forwards operation and returns structured host result',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return <String, Object?>{'ok': true, 'mangas': <Object?>[]};
      });

      final result = await platformChannel.mihonRequest(
        packageName: 'eu.kanade.tachiyomi.extension.all.mangadex',
        operation: 'search',
        sourceId: '1473815169283746501',
        page: 2,
        query: '烙印勇士',
      );

      expect(received?.method, 'mihonRequest');
      expect(received?.arguments, containsPair('operation', 'search'));
      expect(received?.arguments, containsPair('page', 2));
      expect(
        received?.arguments,
        containsPair('sourceId', '1473815169283746501'),
      );
      expect(result, <String, Object?>{'ok': true, 'mangas': <Object?>[]});
    },
  );

  for (final hasSourceText in [true, false]) {
    test(
      'Mihon consumers serialize source metadata, never local edits (${hasSourceText ? 'populated' : 'null'} source text)',
      () async {
        final source = MihonSource(
          packageName: 'extension.example',
          hostSourceId: '123',
          name: 'Example',
          lang: 'zh',
          enabled: true,
          apkPath: '/private/extension.apk',
          versionCode: 1,
          signerSha256: 'publisher',
        );
        final local = MangaMetadataOverride(
          updatedAt: DateTime.utc(2026, 10, 18),
          title: 'Private local title',
          author: 'Private local author',
          description: 'Private local notes',
        );
        final item = MediaItem(
          sourceId: source.descriptor.id,
          remoteId: '/manga/source-id',
          type: MediaType.manga,
          title: 'Source title',
          url: '/manga/source-id',
          author: hasSourceText ? 'Source author' : null,
          description: hasSourceText ? 'Source description' : null,
          tags: const ['Source genre'],
          localMangaMetadata: local,
        );
        final outbound = <(String, Object?)>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'mihonRequest');
          final args = call.arguments as Map;
          final operation = args['operation'] as String;
          if (operation == 'relatedInfo') {
            return {'ok': true, 'supported': true};
          }
          outbound.add((operation, args['manga']));
          return switch (operation) {
            'detail' => {
              'ok': true,
              'url': '/manga/source-id',
              'title': 'Fresh source title',
            },
            'chapters' => {'ok': true, 'chapters': <Object?>[]},
            'related' => {'ok': true, 'mangas': <Object?>[]},
            'browserInfo' => {
              'ok': true,
              'url': 'https://example.org/manga/source-id',
            },
            _ => throw StateError('Unexpected consumer operation $operation'),
          };
        });

        final detail = await source.detail(item);
        expect(detail.sourceTitle, 'Fresh source title');
        expect(detail.localMangaMetadata, isNull);
        expect(await source.chapters(item), isEmpty);
        expect(await source.related(item), isEmpty);
        expect(
          (await source.websiteUri(item: item)).toString(),
          'https://example.org/manga/source-id',
        );
        expect(outbound.map((entry) => entry.$1), [
          'detail',
          'chapters',
          'related',
          'browserInfo',
        ]);
        for (final (_, payload) in outbound) {
          expect(payload, {
            'url': '/manga/source-id',
            'title': 'Source title',
            'thumbnailUrl': null,
            'author': hasSourceText ? 'Source author' : null,
            'description': hasSourceText ? 'Source description' : null,
            'genre': 'Source genre',
          });
        }
        expect(item.title, 'Private local title');
        expect(item.author, 'Private local author');
        expect(item.description, 'Private local notes');
        expect(item.localMangaMetadata, same(local));
      },
    );
  }
}
