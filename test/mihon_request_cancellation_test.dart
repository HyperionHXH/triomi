import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  MihonSource source() => MihonSource(
    packageName: 'org.example.reader',
    hostSourceId: '42',
    name: 'Fixture',
    lang: 'zh',
    enabled: true,
    apkPath: '/private/fixture.apk',
    versionCode: 1,
    signerSha256: null,
  );

  test('cancel waits for its host invocation and never cancels a subsequent reader', () async {
    final entered = Completer<void>();
    final held = Completer<Map<String, Object?>>();
    final cancelled = <String>[];
    final ids = <String?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'mihonCancelRequest') {
        cancelled.add(args['requestId'] as String);
        return null;
      }
      ids.add(args['requestId'] as String?);
      if (ids.length == 1) {
        entered.complete();
        return held.future;
      }
      return {'ok': true, 'pages': <Object?>[]};
    });
    final owner = SourceRequestCancellation();
    final adapter = source();
    const chapter = Chapter(
      sourceId: 'fixture',
      remoteId: 'chapter',
      title: 'Chapter',
    );
    final future = owner.run(() => adapter.content(chapter));
    var finished = false;
    unawaited(
      future.then<void>(
        (_) {
          finished = true;
        },
        onError: (Object _) {
          finished = true;
        },
      ),
    );
    final failure = expectLater(
      future,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await entered.future;
    owner.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, [ids.first]);
    expect(
      finished,
      isFalse,
      reason: 'pause must await the original host cleanup',
    );
    held.complete({'ok': true, 'pages': <Object?>[]});
    await failure;
    await adapter.content(chapter);
    expect(
      ids.last,
      isNull,
      reason: 'normal UI reading does not inherit a download owner',
    );
    expect(cancelled, [ids.first]);
  });

  test(
    'native rate-limit response preserves actual status and Retry-After',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'ok': false,
          'error': 'Rate limited',
          'statusCode': 429,
          'retryAfter': 'Thu, 05 Nov 2026 12:34:56 GMT',
        },
      );
      await expectLater(
        source().content(
          const Chapter(
            sourceId: 'fixture',
            remoteId: 'chapter',
            title: 'Chapter',
          ),
        ),
        throwsA(
          isA<SourceException>()
              .having(
                (error) => error.type,
                'type',
                SourceErrorType.rateLimited,
              )
              .having((error) => error.statusCode, 'statusCode', 429)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                DateTime.utc(2026, 11, 5, 12, 34, 56),
              ),
        ),
      );
    },
  );
}
