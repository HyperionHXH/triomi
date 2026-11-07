import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/detail/anime_info_repository.dart';
import 'package:triomi/features/discover/anime_recommendations.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/library/data/library_providers.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

class _Recommendations extends AnimeRecommendationRepository {
  _Recommendations()
    : super(
        BangumiPublicClient(
          FakeHttpClient((_) async => throw StateError('unexpected network')),
        ),
      );
  @override
  Future<AnimeRecommendationPage> load(
    int offset, {
    AnimeFilter filter = const AnimeFilter(),
  }) async => const AnimeRecommendationPage(
    [
      MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        type: MediaType.anime,
        title: '推荐作品',
        rating: 8.2,
        status: '低价值资料副标题',
        author: '低价值作者副标题',
      ),
    ],
    1,
    false,
  );
}

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'recommendations retain title and score without tiny metadata at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(memoryPreferences()),
              animeRecommendationRepositoryProvider.overrideWithValue(
                _Recommendations(),
              ),
              animeFollowsProvider.overrideWith((_) => Stream.value([])),
            ],
            child: const MaterialApp(
              home: Scaffold(body: AnimeRecommendations()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('推荐作品'), findsOneWidget);
        expect(find.text('8.2'), findsOneWidget);
        expect(find.textContaining('低价值'), findsNothing);
        expect(
          tester
              .widget<MediaItemCollection>(find.byType(MediaItemCollection))
              .showMetadata,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
