import 'dart:convert';
import 'dart:io';

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

class _InstalledSources extends SourceRegistryController {
  _InstalledSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byTooltip('搜索插件名称'), findsOneWidget);
      await tester.tap(find.byTooltip('搜索插件名称'));
      await tester.pump();
      expect(find.byType(TextFormField), findsOneWidget);
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
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.byTooltip('搜索插件名称'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'English');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'English'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'MangaDex'), findsNothing);
      expect(http.requests, hasLength(1));
      await open(2);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.byTooltip('搜索插件名称'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
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
          (request) => request.url == mihonDefaultRepositoryUrl,
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
