// Read-only guest protocol checks. Never changes the persisted account session.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual LNS guest read and permission response', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final connection = FallbackLnsHubConnection(
      primary: SignalRLnsHubConnection(accessToken: () => null),
      fallback: SignalRLnsHubConnection(
        hubUrl: lnsFallbackHubUrl,
        accessToken: () => null,
      ),
    );
    final gateway = LnsGateway(
      connection: connection,
      limiter: ShelfRateLimiter(),
    );
    final record = <String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'environment': 'Android actual SignalR guest requests; no token supplied',
      'permissionModel': 'Official file downloads use CanDownload/DownloadCost; reading has no per-chapter purchase model in announcement 16',
      'chargedDownloadCalled': false,
    };
    try {
      try {
        await gateway.getShelf();
        throw TestFailure('Guest shelf unexpectedly allowed');
      } on SourceException catch (error) {
        record['guestShelf'] = error.type.name;
        expect(error.type, SourceErrorType.auth);
      }
      final item = container
          .read(preferencesProvider)
          .get<Map<dynamic, dynamic>>('acceptance.novel.lns.item');
      expect(item, isNotNull);
      final chapters = await container
          .read(libraryRepositoryProvider)
          .loadChapters(LnsSource.id, '${item!['remoteId']}');
      final chapter = chapters
          .where((c) => !RegExp(r'封面|目录|插画|彩页|书籍信息').hasMatch(c.title))
          .first;
      final key = chapter.remoteId.split(':');
      try {
        final content = await gateway.getNovelContent(
          int.parse(key[0]),
          int.parse(key[1]),
        );
        expect(content.html.length, greaterThan(100));
        throw TestFailure('Guest content unexpectedly allowed');
      } on SourceException catch (error) {
        record['guestContent'] = error.type.name;
        expect(error.type, SourceErrorType.auth);
      }
      final expired = SignalRLnsHubConnection(
        accessToken: () => 'expired.invalid.test',
      );
      try {
        final expiredGateway = LnsGateway(
          connection: expired,
          limiter: ShelfRateLimiter(),
        );
        await expectLater(
          expiredGateway.getShelf(),
          throwsA(
            isA<SourceException>().having(
              (e) => e.type,
              'type',
              SourceErrorType.auth,
            ),
          ),
        );
        record['invalidSessionRejected'] = true;
      } finally {
        expired.reset();
      }
      final snapshot = await container.read(sourcesProvider.future);
      final source =
          snapshot.entries
                  .firstWhere((e) => e.descriptor.id == LnsSource.id)
                  .source
              as LnsSource;
      final permission = await source.gateway.getBookDetail(
        int.parse('${item['remoteId']}'),
      );
      record['officialDownloadPermissionPresent'] =
          permission.canDownload != null;
      record['canDownload'] = permission.canDownload;
      record['downloadCost'] = permission.downloadCost;
      record['status'] = 'passed';
    } finally {
      connection.reset();
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/lns-permission.json')
          .writeAsString(jsonEncode(record), flush: true);
      // ignore: avoid_print
      print('LNS_PERMISSION_EVIDENCE ${jsonEncode(record)}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
