import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/platform/platform_channel.dart';

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
}
