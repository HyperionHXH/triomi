import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/manga/manga_extension_details_page.dart';
import 'package:triomi/features/sources/mihon_extensions_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

Map<String, Object?> extensionJson({
  String packageName = 'eu.kanade.tachiyomi.extension.all.mangadex',
  String language = 'zh',
}) => <String, Object?>{
  'name': 'MangaDex',
  'packageName': packageName,
  'resources': <String, Object?>{
    'apkUrl': 'https://example.com/mangadex.apk',
    'iconUrl': 'https://example.com/icon.png',
  },
  'extensionLib': '1.6',
  'versionCode': '106000',
  'versionName': '1.6.0',
  'sources': <Object?>[
    <String, Object?>{
      'id': 'mangadex',
      'name': 'MangaDex 中文',
      'language': language,
      'homeUrl': 'https://mangadex.org',
    },
  ],
};

Map<String, Object?> _legacyExtensionJson() => {
  'name': 'Tachiyomi: User manga',
  'pkg': 'org.example.user',
  'apk': 'user-v1.apk',
  'version': '1.6.1',
  'code': 1,
  'lang': 'en',
  'nsfw': 0,
  'sources': [
    {
      'id': '1473815169283746501',
      'name': 'User manga',
      'lang': 'en',
      'baseUrl': '',
    },
  ],
};

class _InstalledSources extends SourceRegistryController {
  _InstalledSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

Future<void> _openManagement(
  WidgetTester tester,
  Preferences preferences,
  FakeHttpClient http, {
  int key = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: ValueKey(key),
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        sourceHttpClientProvider.overrideWithValue(http),
        sourcesProvider.overrideWith(
          () => _InstalledSources(const SourceRegistrySnapshot(entries: [], failures: [])),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: MihonExtensionsSheet())),
    ),
  );
  for (var round = 0; round < 6; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _enterRepository(
  WidgetTester tester,
  String url, {
  bool edit = false,
}) async {
  if (!edit) {
    await tester.tap(find.text('仓库'));
    await tester.pump();
    await tester.tap(find.text('添加扩展仓库'));
  } else {
    await tester.tap(find.byTooltip('编辑扩展仓库').last);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
    url,
  );
  await tester.tap(find.widgetWithText(FilledButton, edit ? '保存' : '添加'));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy index and separate store list preserve original repository identity', () async {
    final http = FakeHttpClient((request) async => SourceResponse(
      statusCode: 200,
      body: request.url.endsWith('repo.json')
          ? jsonEncode({
              'meta': {'name': 'User store', 'signingKeyFingerprint': 'original-pin'},
            })
          : jsonEncode([_legacyExtensionJson()]),
    ));
    final index = await MihonRepositoryClient(http).fetch('https://user.example/repo/repo.json');
    expect(index.sourceUrl, 'https://user.example/repo/repo.json');
    expect(index.signingKey, 'original-pin');
    expect(index.extensions.single.name, 'User manga');
    expect(index.extensions.single.apkUrl, 'https://user.example/repo/apk/user-v1.apk');
    expect(index.extensions.single.sources.single.id, '1473815169283746501');
    expect(http.requests.map((request) => request.url), [
      'https://user.example/repo/repo.json',
      'https://user.example/repo/index.min.json',
    ]);
  });

  test('external list URLs reject credentials before a second request', () async {
    final http = FakeHttpClient((_) async => SourceResponse(
      statusCode: 200,
      body: jsonEncode({'extensionListUrl': 'https://user:secret@example.com/list.json'}),
    ));
    await expectLater(
      MihonRepositoryClient(http).fetch('https://user.example/repo.json'),
      throwsA(isA<MihonRepositoryParseException>()),
    );
    expect(http.requests, hasLength(1));
  });

  for (final legacy in [false, true]) {
    test('direct redirected ${legacy ? 'legacy' : 'extended'} list retains declared provenance', () async {
      const original = 'https://user.example/repo/index.json';
      const finalUrl = 'https://delivery.example/releases/v2/index.json';
      final http = FakeHttpClient((request) async => SourceResponse(
        statusCode: 200,
        url: finalUrl,
        body: jsonEncode(legacy
            ? [_legacyExtensionJson()]
            : {
                'name': 'Declared index',
                'signingKey': 'declared-pin',
                'extensions': [extensionJson()],
              }),
      ));

      final index = await MihonRepositoryClient(http).fetch(original);

      expect(http.requests.map((request) => request.url), [original]);
      expect(index.sourceUrl, original);
      expect(index.signingKey, legacy ? '' : 'declared-pin');
      expect(
        index.extensions.single.apkUrl,
        legacy
            ? 'https://delivery.example/releases/v2/apk/user-v1.apk'
            : 'https://example.com/mangadex.apk',
      );
      expect(
        index.extensions.single.iconUrl,
        legacy
            ? 'https://delivery.example/releases/v2/icon/org.example.user.png'
            : 'https://example.com/icon.png',
      );
    });
  }

  for (final redirected in [false, true]) {
    for (final field in ['extensionList', 'extensionListUrl', 'index_v2', 'meta']) {
      test('$field descriptor follows ${redirected ? 'redirected' : 'direct'} resources without changing publisher provenance', () async {
        const original = 'https://user.example/repo/repo.json';
        final descriptorUrl = redirected
            ? 'https://delivery.example/catalog/repo.json'
            : original;
        final listRequest = redirected
            ? 'https://delivery.example/catalog/index.min.json'
            : 'https://user.example/repo/index.min.json';
        final listUrl = redirected
            ? 'https://packages.example/release/index.min.json'
            : listRequest;
        final http = FakeHttpClient((request) async {
          if (request.url == original) {
            return SourceResponse(
              statusCode: 200,
              url: descriptorUrl,
              body: jsonEncode({
                'meta': {
                  'name': 'Metadata store',
                  'signingKeyFingerprint': 'metadata-pin',
                },
                if (field != 'meta') field: ' index.min.json ',
                if (field == 'extensionList') ...{
                  'name': 'Declared store',
                  'signingKey': 'declared-pin',
                },
              }),
            );
          }
          expect(request.url, listRequest);
          return SourceResponse(
            statusCode: 200,
            url: listUrl,
            body: jsonEncode([_legacyExtensionJson()]),
          );
        });

        final index = await MihonRepositoryClient(http).fetch(original);

        expect(http.requests.map((request) => request.url), [original, listRequest]);
        expect(index.sourceUrl, original);
        expect(index.name, field == 'extensionList' ? 'Declared store' : 'Metadata store');
        expect(index.signingKey, field == 'extensionList' ? 'declared-pin' : 'metadata-pin');
        expect(
          index.extensions.single.apkUrl,
          redirected
              ? 'https://packages.example/release/apk/user-v1.apk'
              : 'https://user.example/repo/apk/user-v1.apk',
        );
      });
    }
  }

  test('nested redirected descriptors retain outer signing metadata and original provenance', () async {
    const original = 'https://user.example/repo.json';
    const nested = 'https://delivery.example/catalog/nested/repo.json';
    const list = 'https://mirror.example/current/lists/index.json';
    final http = FakeHttpClient((request) async {
      if (request.url == original) {
        return SourceResponse(
          statusCode: 200,
          url: 'https://delivery.example/catalog/repo.json',
          body: jsonEncode({
            'name': 'Original repository',
            'signingKey': 'original-pin',
            'extensionList': 'nested/repo.json',
          }),
        );
      }
      if (request.url == nested) {
        return SourceResponse(
          statusCode: 200,
          url: 'https://mirror.example/current/metadata/repo.json',
          body: jsonEncode({
            'name': 'Nested repository',
            'signingKey': 'nested-pin',
            'extensionListUrl': '../lists/index.json',
          }),
        );
      }
      expect(request.url, list);
      return SourceResponse(
        statusCode: 200,
        url: 'https://packages.example/releases/index.json',
        body: jsonEncode([_legacyExtensionJson()]),
      );
    });

    final index = await MihonRepositoryClient(http).fetch(original);

    expect(http.requests.map((request) => request.url), [original, nested, list]);
    expect(index.sourceUrl, original);
    expect(index.name, 'Original repository');
    expect(index.signingKey, 'original-pin');
    expect(index.extensions.single.apkUrl, 'https://packages.example/releases/apk/user-v1.apk');
  });

  for (final unsafeUrl in [
    'http://delivery.example/index.json',
    'https://user:secret@delivery.example/index.json',
    'https://delivery.example/index.json#fragment',
    '/relative/index.json',
    'https://',
  ]) {
    for (final nested in [false, true]) {
      test('rejects unsafe final URL $unsafeUrl at ${nested ? 'nested list' : 'descriptor'} before consuming content', () async {
        const original = 'https://user.example/repo.json';
        const list = 'https://user.example/index.min.json';
        final http = FakeHttpClient((request) async => SourceResponse(
          statusCode: 200,
          url: nested && request.url == original ? original : unsafeUrl,
          body: jsonEncode(request.url == original
              ? {'extensionList': 'index.min.json'}
              : {'extensions': [extensionJson()]}),
        ));

        await expectLater(
          MihonRepositoryClient(http).fetch(original),
          throwsA(isA<MihonRepositoryParseException>()),
        );

        expect(http.requests.map((request) => request.url), nested ? [original, list] : [original]);
      });
    }
  }

  for (final descriptor in [false, true]) {
    test('official API recovery resolves ${descriptor ? 'descriptor and nested legacy list' : 'direct legacy list'} against the declared raw resource', () async {
      final original = descriptor
          ? 'https://raw.githubusercontent.com/owner/repo/pinned/repository/repo.json'
          : 'https://raw.githubusercontent.com/owner/repo/pinned/repository/index.min.json';
      final indexRequest = 'https://raw.githubusercontent.com/owner/repo/pinned/repository/index.min.json';
      final originalApi = descriptor
          ? 'https://api.github.com/repos/owner/repo/contents/repository/repo.json?ref=pinned'
          : 'https://api.github.com/repos/owner/repo/contents/repository/index.min.json?ref=pinned';
      const indexApi = 'https://api.github.com/repos/owner/repo/contents/repository/index.min.json?ref=pinned';
      final adapter = _RepositoryAdapter((options) {
        if (options.uri.host == 'raw.githubusercontent.com') {
          throw DioException.connectionTimeout(
            requestOptions: options,
            timeout: const Duration(seconds: 20),
          );
        }
        expect(options.headers['Accept'], 'application/vnd.github.raw+json');
        expect(options.followRedirects, isFalse);
        expect(options.uri.toString(), anyOf(originalApi, indexApi));
        return ResponseBody.fromString(
          jsonEncode(descriptor && options.uri.toString() == originalApi
              ? {
                  'name': 'Pinned repository',
                  'signingKey': 'declared-pin',
                  'extensionList': 'index.min.json',
                }
              : [_legacyExtensionJson()]),
          200,
        );
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);

      final index = await MihonRepositoryClient(http).fetch(original);

      expect(adapter.requests.map((request) => request.uri.toString()), [
        original,
        originalApi,
        if (descriptor) ...[indexRequest, indexApi],
      ]);
      expect(index.sourceUrl, original);
      expect(index.signingKey, descriptor ? 'declared-pin' : '');
      expect(index.extensions.single.apkUrl, 'https://raw.githubusercontent.com/owner/repo/pinned/repository/apk/user-v1.apk');
      expect(index.extensions.single.iconUrl, 'https://raw.githubusercontent.com/owner/repo/pinned/repository/icon/org.example.user.png');
    });
  }

  test('unrelated API redirects use their final resource instead of substituting the old raw repository', () async {
    const original = 'https://raw.githubusercontent.com/owner/repo/pinned/index.min.json';
    final http = FakeHttpClient((_) async => SourceResponse(
      statusCode: 200,
      url: 'https://api.github.com/repos/owner/other/contents/index.min.json?ref=pinned',
      body: jsonEncode([_legacyExtensionJson()]),
    ));

    final index = await MihonRepositoryClient(http).fetch(original);

    expect(http.requests.map((request) => request.url), [original]);
    expect(index.sourceUrl, original);
    expect(index.extensions.single.apkUrl, 'https://api.github.com/repos/owner/other/contents/apk/user-v1.apk');
  });

  for (final resource in ['apkUrl', 'jarUrl']) {
    for (final unsafeUrl in [
      'plugin.${resource == 'apkUrl' ? 'apk' : 'jar'}',
      'http://delivery.example/plugin',
      'https://user:secret@delivery.example/plugin',
    ]) {
      test('redirected extended list keeps strict $resource validation for $unsafeUrl', () async {
        const original = 'https://user.example/index.json';
        final extension = extensionJson();
        (extension['resources']! as Map<String, Object?>)[resource] = unsafeUrl;
        final http = FakeHttpClient((_) async => SourceResponse(
          statusCode: 200,
          url: 'https://delivery.example/current/index.json',
          body: jsonEncode({'extensions': [extension]}),
        ));

        await expectLater(
          MihonRepositoryClient(http).fetch(original),
          throwsA(isA<MihonRepositoryParseException>()),
        );

        expect(http.requests.map((request) => request.url), [original]);
      });
    }
  }

  testWidgets('manual repository CRUD persists removal and never seeds a fresh profile', (tester) async {
    final preferences = memoryPreferences();
    final http = FakeHttpClient((_) async => SourceResponse(
      statusCode: 200,
      body: jsonEncode({'extensions': [extensionJson(language: 'en')]}),
    ));
    await _openManagement(tester, preferences, http);
    expect(http.requests, isEmpty);
    expect(preferences.get<Object?>('mihon.repositories'), isNull);
    expect(find.byType(TextFormField), findsOneWidget);
    await _enterRepository(tester, 'https://manual.example/first.json');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'MangaDex'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'MangaDex');
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'MangaDex'), findsOneWidget);
    await tester.tap(find.text('仓库'));
    await tester.pump();
    await _enterRepository(tester, 'https://manual.example/edited.json', edit: true);
    await tester.pumpAndSettle();
    expect(preferences.get<List<Object?>>('mihon.repositories'), ['https://manual.example/edited.json']);
    await tester.tap(find.text('仓库'));
    await tester.pump();
    await tester.tap(find.byTooltip('移除扩展仓库'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();
    expect(preferences.get<List<Object?>>('mihon.repositories'), isEmpty);
    final requests = http.requests.length;
    await _openManagement(tester, preferences, http, key: 1);
    expect(http.requests, hasLength(requests));
    expect(preferences.get<List<Object?>>('mihon.repositories'), isEmpty);
    expect(find.widgetWithText(ListTile, 'MangaDex'), findsNothing);
    expect(tester.widget<TextFormField>(find.byType(TextFormField)).controller?.text, 'MangaDex');
  });

  testWidgets('adding a repository during an old fetch ignores its late result', (tester) async {
    final preferences = memoryPreferences();
    await preferences.set('mihon.repositories', ['https://old.example/index.json']);
    final old = Completer<SourceResponse>();
    final current = Completer<SourceResponse>();
    final http = FakeHttpClient((request) =>
      request.url.contains('old.example') ? old.future : current.future);
    await _openManagement(tester, preferences, http);
    await _enterRepository(tester, 'https://current.example/index.json');
    await tester.pump(const Duration(milliseconds: 300));
    expect(http.requests.map((request) => request.url), [
      'https://old.example/index.json', 'https://current.example/index.json',
    ]);
    current.complete(SourceResponse(statusCode: 200, body: jsonEncode({
      'extensions': [extensionJson()..['name'] = 'Current plugin'],
    })));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Current plugin'), findsOneWidget);
    old.complete(SourceResponse(statusCode: 200, body: jsonEncode({
      'extensions': [extensionJson()..['name'] = 'Stale plugin'],
    })));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Current plugin'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Stale plugin'), findsNothing);
    expect(preferences.get<List<Object?>>('mihon.repositories'), [
      'https://old.example/index.json', 'https://current.example/index.json',
    ]);
  });

  testWidgets('unavailable installed plugins open diagnostics without a repository and can uninstall', (tester) async {
    const package = 'org.example.unavailable';
    final preferences = memoryPreferences();
    await preferences.set('sources.filters.mihon', {'language': 'zh', 'content': 'safe'});
    await preferences.set('mihon.installedPackages', {package: '1'});
    await preferences.set('mihon.hostStatus', {
      package: {
        'ok': false,
        'name': 'Unavailable English plugin',
        'hostError': 'Missing desktop runtime payload',
        'lang': 'en',
      },
    });
    final http = FakeHttpClient((_) async => throw StateError('Repository offline'));
    const host = MethodChannel('triomi/platform');
    final nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (call) async {
          nativeCalls.add(call);
          return {'ok': true};
        });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null));
    await _openManagement(tester, preferences, http);
    expect(http.requests, isEmpty);
    expect(find.text('Unavailable English plugin'), findsOneWidget);
    await tester.tap(find.text('Unavailable English plugin'));
    await tester.pumpAndSettle();
    expect(find.byType(MangaExtensionDetailsPage), findsOneWidget);
    expect(find.textContaining('Missing desktop runtime payload'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('卸载扩展'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保留书架'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await tester.pumpAndSettle();
    expect(nativeCalls.map((call) => call.method), ['mihonUninstall']);
    expect(preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages'), isEmpty);
    expect(preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus'), isEmpty);
    expect(find.text('Unavailable English plugin'), findsNothing);
  });

  testWidgets('rejected native enable never reports an enabled plugin', (tester) async {
    const package = 'org.example.rejected';
    final preferences = memoryPreferences();
    await preferences.set('mihon.installedPackages', {package: '1'});
    await preferences.set('mihon.hostStatus', {package: {'ok': true, 'name': 'Rejected'}});
    final http = FakeHttpClient((_) async => throw StateError('No repository'));
    const host = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (_) async => {'ok': false});
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null));
    await _openManagement(tester, preferences, http);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(preferences.get<List<Object?>>('mihon.enabledPackages'), isEmpty);
    expect(find.textContaining('宿主没有接受启用状态变更'), findsOneWidget);
    expect(http.requests, isEmpty);
  });

  testWidgets('publisher confirmation remains bound to the original index after repository selection changes', (tester) async {
    const original = 'https://original.example/index.json';
    const selected = 'https://selected.example/index.json';
    final preferences = memoryPreferences();
    await preferences.set('mihon.repositories', [original]);
    final http = FakeHttpClient((request) async => SourceResponse(
      statusCode: 200,
      body: jsonEncode({
        'signingKey': request.url == original ? 'original-repository-pin' : 'selected-repository-pin',
        'extensions': [extensionJson()],
      }),
    ))..bytesHandler = (_) => [1, 2, 3];
    const host = MethodChannel('triomi/platform');
    final metadata = Completer<Map<String, Object?>>();
    final metadataRequested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (call) async {
          if (call.method == 'mihonInspectMetadata') {
            metadataRequested.complete();
            return metadata.future;
          }
          throw StateError('Unconfirmed extension must never execute');
        });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null));
    await _openManagement(tester, preferences, http);
    await tester.tap(find.byTooltip('下载 APK'));
    await tester.pump();
    for (var attempt = 0; attempt < 100 && !metadataRequested.isCompleted; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(metadataRequested.isCompleted, isTrue);
    await _enterRepository(tester, selected);
    await tester.pump(const Duration(milliseconds: 300));
    metadata.complete({
      'ok': true,
      'signatureVerified': true,
      'signerSha256': 'a' * 64,
      'sha256': 'b' * 64,
      'stagedPath': '/private/staged.apk',
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('仓库：$original'), findsOneWidget);
    expect(find.text('original-repository-pin'), findsOneWidget);
    expect(find.text('selected-repository-pin'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(preferences.get<Object?>('mihon.installedPackages'), isNull);
    await tester.tap(find.text('已安装'));
    await tester.pumpAndSettle();
    expect(find.text('MangaDex'), findsOneWidget);
    await tester.tap(find.text('MangaDex'));
    await tester.pumpAndSettle();
    expect(find.byType(MangaExtensionDetailsPage), findsOneWidget);
    expect(find.textContaining('尚未确认扩展发布者'), findsOneWidget);
  });
  late Directory support;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    support = await Directory.systemTemp.createTemp('mihon-sheet-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => support.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await support.delete(recursive: true);
  });
  test('解析 Mihon extensionList 并按中文和类型筛选', () {
    final index = MihonRepositoryParser.parse(
      jsonEncode(<String, Object?>{
        'name': '测试仓库',
        'signingKey': 'abc',
        'extensionList': <String, Object?>{
          'extensions': <Object?>[
            extensionJson(),
            extensionJson(
              packageName: 'eu.kanade.tachiyomi.extension.en.other',
              language: 'en',
            ),
          ],
        },
      }),
      sourceUrl: 'https://example.com/index.json',
    );

    expect(index.extensions, hasLength(2));
    expect(index.filter(language: 'zh'), hasLength(1));
    expect(index.filter(query: 'mangadex'), hasLength(2));
    expect(index.extensions.first.mediaType, MediaType.manga);
    expect(index.extensions.first.apkUrl, startsWith('https://'));
  });

  test('拒绝不安全 APK 地址和缺失扩展数组', () {
    expect(
      () => MihonRepositoryParser.parse(
        jsonEncode(<String, Object?>{
          'extensionList': <String, Object?>{
            'extensions': <Object?>[
              extensionJson()
                ..['resources'] = <String, Object?>{'apkUrl': 'http://bad'},
            ],
          },
        }),
        sourceUrl: 'https://example.com/index.json',
      ),
      throwsA(isA<MihonRepositoryParseException>()),
    );
    expect(
      () => MihonRepositoryParser.parse(
        '{"name":"empty"}',
        sourceUrl: 'https://example.com/index.json',
      ),
      throwsA(isA<MihonRepositoryParseException>()),
    );
  });

  test('保留 Mihon 的 64 位来源 id，不把来源身份缩窄为 number', () {
    final payload = extensionJson();
    final sources = payload['sources']! as List<Object?>;
    (sources.single as Map<String, Object?>)['id'] = '1473815169283746501';

    final index = MihonRepositoryParser.parse(
      jsonEncode(<String, Object?>{
        'name': '真实格式兼容',
        'extensionList': <String, Object?>{
          'extensions': <Object?>[payload],
        },
      }),
      sourceUrl: 'https://repo.example/index.json',
    );

    expect(index.extensions.single.sources.single.id, '1473815169283746501');
  });

  test('兼容真实仓库省略 source.homeUrl 的来源', () {
    final payload = extensionJson();
    final source =
        (payload['sources']! as List<Object?>).single as Map<String, Object?>;
    source.remove('homeUrl');
    final index = MihonRepositoryParser.parse(
      jsonEncode(<String, Object?>{
        'extensionList': <String, Object?>{
          'extensions': <Object?>[payload],
        },
      }),
      sourceUrl: 'https://repo.example/index.json',
    );
    expect(index.extensions.single.sources.single.homeUrl, isEmpty);
  });

  test('兼容仓库索引的顶层 extensions 形式，并保留警告字段', () {
    final payload = extensionJson()..['contentWarning'] = '需要登录';
    final index = MihonRepositoryParser.parse(
      jsonEncode(<String, Object?>{
        'name': '兼容仓库',
        'extensions': <Object?>[payload],
      }),
      sourceUrl: 'https://repo.example/index.json',
    );

    expect(index.extensions.single.contentWarning, '需要登录');
  });

  test('空来源扩展不推导漫画或小说能力', () {
    final payload = extensionJson()..['sources'] = <Object?>[];
    final index = MihonRepositoryParser.parse(
      jsonEncode(<String, Object?>{
        'extensionList': <String, Object?>{
          'extensions': <Object?>[payload],
        },
      }),
      sourceUrl: 'https://repo.example/index.json',
    );

    final extension = index.extensions.single;
    expect(extension.sources, isEmpty);
    expect(extension.mediaType, isNull);
    expect(extension.hasChineseSource, isFalse);
    expect(index.filter(type: MediaType.manga), isEmpty);
  });

  test('客户端在网络请求前拒绝非 HTTPS 仓库地址', () async {
    final http = _CountingHttpClient();
    final client = MihonRepositoryClient(http);

    await expectLater(
      client.fetch('http://repo.example/index.json'),
      throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.parse,
        ),
      ),
    );
    expect(http.requests, 0);
  });

  testWidgets('恢复启用偏好但宿主未执行时明确显示不可用状态', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final preferences = memoryPreferences();
      await preferences.set('mihon.enabledPackages', <String>[
        'eu.kanade.tachiyomi.extension.all.mangadex',
      ]);
      await preferences.set('mihon.installedPackages', <String, String>{
        'eu.kanade.tachiyomi.extension.all.mangadex': '1.6.0',
      });
      await preferences.set('mihon.hostStatus', <String, Object?>{
        'eu.kanade.tachiyomi.extension.all.mangadex': <String, Object?>{
          'ok': false,
          'sources': [
            {'name': 'MangaDex', 'lang': 'zh', 'id': '1'},
          ],
          'factoryLoaded': true,
          'hostError': '等待 Mihon source-api 运行时',
        },
      });
      final http = FakeHttpClient(
        (_) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'name': '测试仓库',
            'extensionList': <String, Object?>{
              'extensions': <Object?>[extensionJson()],
            },
          }),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourceHttpClientProvider.overrideWithValue(http),
          ],
          child: const MaterialApp(
            home: Scaffold(body: MihonExtensionsSheet()),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();

      expect(http.requests, isEmpty);
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.byTooltip('搜索插件名称'), findsNothing);
      await tester.enterText(find.byType(TextFormField), '不存在的插件');
      await tester.pump();
      expect(find.byType(Switch), findsNothing);
      await tester.enterText(find.byType(TextFormField), '');
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      final switchNode = tester.getSemantics(
        find.bySemanticsLabel('启用扩展 MangaDex'),
      );
      expect(
        switchNode,
        isSemantics(
          label: '启用扩展 MangaDex',
          hasToggledState: true,
          isToggled: false,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('宿主已执行时启用开关写回偏好', (tester) async {
    const host = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (_) async => {'ok': true});
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(host, null),
    );
    final semantics = tester.ensureSemantics();
    try {
      final preferences = memoryPreferences();
      await preferences.set('mihon.hostStatus', <String, Object?>{
        'eu.kanade.tachiyomi.extension.all.mangadex': <String, Object?>{
          'ok': true,
          'sources': [
            {'name': 'MangaDex', 'lang': 'zh', 'id': '1'},
          ],
        },
      });
      await preferences.set('mihon.installedPackages', <String, String>{
        'eu.kanade.tachiyomi.extension.all.mangadex': '1.6.0',
      });
      final http = FakeHttpClient(
        (_) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'name': '测试仓库',
            'extensionList': <String, Object?>{
              'extensions': <Object?>[extensionJson()],
            },
          }),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourceHttpClientProvider.overrideWithValue(http),
          ],
          child: const MaterialApp(
            home: Scaffold(body: MihonExtensionsSheet()),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();

      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      expect(http.requests, isEmpty);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        preferences.get<List<Object?>>('mihon.enabledPackages'),
        contains('eu.kanade.tachiyomi.extension.all.mangadex'),
      );
      final switchNode = tester.getSemantics(
        find.bySemanticsLabel('启用扩展 MangaDex'),
      );
      expect(
        switchNode,
        isSemantics(
          label: '启用扩展 MangaDex',
          hasToggledState: true,
          isToggled: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
    'plugin name query persists without changing installed or trust state',
    (tester) async {
      final preferences = memoryPreferences();
      const repositoryUrl = 'https://custom.example/index.json';
      const package = 'eu.kanade.tachiyomi.extension.all.mangadex';
      const installed = {package: '1.6.0'};
      const enabled = [package];
      const hostStatus = {
        package: {
          'ok': true,
          'signerSha256': 'fixture-publisher-pin',
          'sha256': 'fixture-content-pin',
          'sources': [
            {'name': 'MangaDex', 'lang': 'zh', 'id': '1'},
          ],
        },
      };
      await preferences.set('mihon.installedPackages', installed);
      await preferences.set('mihon.enabledPackages', enabled);
      await preferences.set('mihon.hostStatus', hostStatus);
      await preferences.set('mihon.repositories', [repositoryUrl]);
      final http = FakeHttpClient(
        (_) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'extensions': [
              extensionJson(),
              extensionJson(packageName: 'org.example.english', language: 'en')
                ..['name'] = 'English',
            ],
          }),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async => container.dispose());
      });
      Future<void> open(int key) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(body: MihonExtensionsSheet(key: ValueKey(key))),
            ),
          ),
        );
        for (var round = 0; round < 6; round++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      await open(1);
      expect(http.requests, isEmpty);
      await tester.tap(find.text('浏览扩展'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'MangaDex'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'English'), findsOneWidget);
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'English');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'English'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'MangaDex'), findsNothing);
      expect(http.requests, hasLength(1));
      await open(2);
      expect(find.byType(TextFormField), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).controller?.text,
        'English',
      );
      expect(find.widgetWithText(ListTile, 'MangaDex'), findsNothing);
      await tester.tap(find.text('浏览扩展'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'English'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'MangaDex'), findsNothing);
      expect(preferences.get<Object?>('mihon.enabledPackages'), enabled);
      expect(preferences.get<Object?>('mihon.installedPackages'), installed);
      expect(preferences.get<Object?>('mihon.hostStatus'), hostStatus);
      await tester.enterText(find.byType(TextFormField), package);
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNothing);
      await tester.enterText(find.byType(TextFormField), '');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'MangaDex'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'English'), findsOneWidget);
      expect(http.requests, hasLength(2));
      expect(
        http.requests.every(
          (request) => request.url == repositoryUrl,
        ),
        isTrue,
      );
      expect(preferences.get<Object?>('mihon.enabledPackages'), enabled);
      expect(preferences.get<Object?>('mihon.installedPackages'), installed);
      expect(preferences.get<Object?>('mihon.hostStatus'), hostStatus);
    },
  );
  testWidgets(
    'installed plugin row and gear both open per-source details without changing enablement',
    (tester) async {
      const package = 'extension.installed';
      final preferences = memoryPreferences();
      await preferences.set('mihon.installedPackages', {package: '1.6.0'});
      await preferences.set('mihon.enabledPackages', [package]);
      await preferences.set('mihon.hostStatus', {
        package: {
          'ok': true,
          'sources': [
            {'id': '1', 'name': 'Installed comic source', 'lang': 'zh'},
          ],
        },
      });
      final source = MihonSource(
        packageName: package,
        hostSourceId: '1',
        name: 'Installed comic source',
        lang: 'zh',
        enabled: true,
        apkPath: null,
        versionCode: 1,
        signerSha256: null,
        isConfigurable: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourcesProvider.overrideWith(
              () => _InstalledSources(
                SourceRegistrySnapshot(
                  entries: [
                    SourceEntry(
                      descriptor: source.descriptor,
                      source: source,
                      enabled: true,
                    ),
                  ],
                  failures: const [],
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: MihonExtensionsSheet()),
          ),
        ),
      );
      for (var round = 0; round < 6; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byTooltip('插件详情与来源设置'), findsOneWidget);
      await tester.tap(find.text('Installed comic source'));
      await tester.pumpAndSettle();
      expect(find.byType(MangaExtensionDetailsPage), findsOneWidget);
      expect(find.text('此来源没有提供可配置设置'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('插件详情与来源设置'));
      await tester.pumpAndSettle();
      expect(find.byType(MangaExtensionDetailsPage), findsOneWidget);
      expect(preferences.get<List<Object?>>('mihon.enabledPackages'), [
        package,
      ]);
    },
  );
}

class _RepositoryAdapter implements HttpClientAdapter {
  _RepositoryAdapter(this.reply);

  final ResponseBody Function(RequestOptions) reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

class _CountingHttpClient implements SourceHttpClient {
  var requests = 0;

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) async {
    requests++;
    return const SourceResponse(statusCode: 200, body: '{}');
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    String method = 'GET',
  }) async => <int>[];

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    bool followRedirects = true,
  }) async =>
      SourceByteStream(stream: const Stream<List<int>>.empty(), url: url);

  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const <String, String>{},
    String method = 'PUT',
  }) async => const SourceResponse(statusCode: 200, body: '');

  @override
  void close() {}
}
