import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/tracking/bind_sheet.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_providers.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  for (final type in MediaType.values) {
    testWidgets(
      '${type.name} binding searches same-title works in its remote media category',
      (tester) async {
        final db = openTestDatabase();
        final secure = MemorySecureStore();
        await secure.set(TrackingServiceKind.bangumi.tokenKey, 'test-token');
        await secure.set(TrackingServiceKind.anilist.tokenKey, 'test-token');
        final http = FakeHttpClient((request) async {
          final body = jsonDecode(request.body!) as Map<String, dynamic>;
          if (Uri.parse(request.url).path == '/v0/search/subjects') {
            final book = (body['filter']['type'] as List).single == 1;
            return SourceResponse(
              statusCode: 200,
              body: jsonEncode({
                'data': [
                  {
                    'id': book ? 2 : 1,
                    'name': book ? '同名书籍版本' : '同名动画版本',
                    'name_cn': '同名作品',
                    'eps': book ? 60 : 12,
                  },
                ],
              }),
            );
          }
          final query = body['query'] as String;
          final String edition;
          final int id;
          if (query.contains('type: ANIME')) {
            edition = '动画版本';
            id = 10;
          } else if (query.contains('format_not: NOVEL')) {
            edition = '漫画版本';
            id = 20;
          } else if (query.contains('format: NOVEL')) {
            edition = '小说版本';
            id = 30;
          } else {
            return const SourceResponse(
              statusCode: 400,
              body: '{"errors":[{"message":"media category required"}]}',
            );
          }
          return SourceResponse(
            statusCode: 200,
            body: jsonEncode({
              'data': {
                'Page': {
                  'media': [
                    {
                      'id': id,
                      'title': {'romaji': '同名作品', 'native': edition},
                      'episodes': 12,
                      'chapters': 60,
                    },
                  ],
                },
              },
            }),
          );
        });
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(memoryPreferences()),
            secureStoreProvider.overrideWithValue(secure),
            sourceHttpClientProvider.overrideWithValue(http),
          ],
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showTrackingBindSheet(
                        context,
                        MediaItem(
                          sourceId: 'source-${type.name}',
                          remoteId: 'same',
                          type: type,
                          title: '同名作品',
                        ),
                      ),
                      child: const Text('绑定'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('绑定'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              type == MediaType.anime ? '同名动画版本 · 共 12 集' : '同名书籍版本 · 共 60 章',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('AniList'));
          await tester.pumpAndSettle();
          final edition = switch (type) {
            MediaType.anime => '动画版本 · 共 12 集',
            MediaType.manga => '漫画版本 · 共 60 章',
            MediaType.novel => '小说版本 · 共 60 章',
          };
          expect(find.text(edition), findsOneWidget);
          final binds = await tester.runAsync(
            () => container.read(trackingRepositoryProvider).allBinds(),
          );
          expect(binds, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            container.dispose();
            await db.close();
          });
          await tester.pump(const Duration(milliseconds: 1));
        }
      },
    );
  }
}
