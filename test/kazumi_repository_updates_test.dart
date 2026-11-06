import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/kazumi_repository.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

Map<String, Object?> _rule(String name, String version) => {
  'api': '9',
  'name': name,
  'version': version,
  'type': 'anime',
  'baseURL': 'https://anime.test',
  'searchURL': 'https://anime.test/search?q=@keyword',
  'searchList': '//li',
  'searchName': '//a',
  'searchResult': '//a',
  'chapterRoads': '//ul',
  'chapterResult': '//li/a',
};

class _SecureHttp extends FakeHttpClient implements SecureRuleDownloadClient {
  _SecureHttp(super.handler);
  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) => downloadBytes(url, sourceId: sourceId);
}

class _BodyTimeoutHttp extends _SecureHttp {
  _BodyTimeoutHttp()
    : super(
        (_) async => throw StateError('Only secure streaming is supported'),
      );

  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) async {
    requests.add(
      SourceRequest(url: url, headers: const {'Cookie': 'inherited-session'}),
    );
    return SourceByteStream(
      url: url,
      stream: Stream<List<int>>.error(
        TimeoutException('Body stalled after response headers'),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late SourceRegistry registry;
  late KazumiRepository client;
  final versions = <String, String>{};
  final failures = <String>{};
  var changedSameVersion = false;
  Future<void> Function(SourceRequest)? beforeResponse;
  late _SecureHttp http;
  const repoA = 'https://a.test/rules/index.json';
  const repoB = 'https://b.test/rules/index.json';

  setUp(() {
    versions.clear();
    failures.clear();
    changedSameVersion = false;
    beforeResponse = null;
    db = openTestDatabase();
    http = _SecureHttp((request) async {
      await beforeResponse?.call(request);
      final uri = Uri.parse(request.url);
      final name = uri.pathSegments.last.replaceFirst('.json', '');
      if (failures.contains(name)) throw StateError('upstream unavailable');
      final isA = uri.host == 'a.test';
      final body = name == 'index'
          ? [
              for (final name
                  in isA ? ['alpha', 'broken', 'removed'] : ['beta'])
                {'name': name, 'version': versions[name] ?? '1.0'},
            ]
          : {
              ..._rule(name, versions[name] ?? '1.0'),
              if (changedSameVersion) 'userAgent': 'same-version mutation',
            };
      return SourceResponse(
        statusCode: 200,
        body: jsonEncode(body),
        url: request.url,
      );
    });
    registry = SourceRegistry(repository: SourceRepository(db), http: http);
    client = KazumiRepository(registry);
  });
  tearDown(() async {
    registry.dispose();
    await db.close();
  });

  Future<String> install(String name, String repo) async {
    final source = await client.install(
      repo,
      KazumiCatalogEntry(name: name, version: versions[name] ?? '1.0'),
    );
    return source.id;
  }

  test('public acceleration ignores stale mirror snapshots for discovery and updates', () async {
    final currentText = await rootBundle.loadString(
      'assets/catalog/kazumi-official-index.json',
    );
    final current = jsonDecode(currentText) as List;
    final stale = [
      for (final entry in current)
        if (entry['name'] != 'TvTFun')
          {...entry as Map, if (entry['name'] == 'AGE') 'version': '1.5'},
    ];
    final ageText = await rootBundle.loadString('assets/rules/kazumi-AGE.json');
    final transport = _SecureHttp((request) async {
      final uri = Uri.parse(request.url);
      return SourceResponse(
        statusCode: 200,
        url: request.url,
        body: uri.host == 'raw.gitcode.com'
            ? jsonEncode(stale)
            : uri.pathSegments.last == 'index.json'
            ? currentText
            : ageText,
      );
    });
    final sources = SourceRegistry(
      repository: SourceRepository(db),
      http: transport,
    );
    addTearDown(sources.dispose);
    final canonical = KazumiRepository(sources, allowPublicFallback: true);
    final entries = await canonical.load(KazumiRepository.defaultRepository);
    expect(entries, hasLength(18));
    expect(entries.singleWhere((entry) => entry.name == 'AGE').version, '1.6');
    final id = KazumiRule.idForName('AGE');
    await sources.repository.upsert(
      id: id,
      name: 'AGE',
      type: MediaType.anime,
      kind: SourceKind.plugin,
      ruleText: jsonEncode(_rule('AGE', '1.5')),
      version: '1.5',
      repoUrl: KazumiRepository.defaultRepository,
      enabled: false,
    );
    final results = await canonical.refreshInstalled(
      repositories: {KazumiRepository.defaultRepository: true},
      update: true,
    );
    expect(results.single.updated, isTrue);
    final stored = (await sources.repository.byId(id))!;
    expect(stored.version, '1.6');
    expect(stored.ruleText, ageText);
    expect(stored.enabled, isFalse);
    expect(
      transport.requests.every(
        (request) => Uri.parse(request.url).host == 'raw.githubusercontent.com',
      ),
      isTrue,
    );
  });

  test('official raw transport deadline recovers only through GitHub owned content API', () async {
    final catalog = await rootBundle.loadString(
      'assets/catalog/kazumi-official-index.json',
    );
    final age = await rootBundle.loadString('assets/rules/kazumi-AGE.json');
    final transport = _SecureHttp((request) async {
      final uri = Uri.parse(request.url);
      if (uri.host == 'raw.githubusercontent.com') {
        throw DioException(
          requestOptions: RequestOptions(path: request.url),
          type: DioExceptionType.connectionTimeout,
        );
      }
      expect(uri.host, 'api.github.com');
      expect(uri.queryParameters, {'ref': 'main'});
      final name = uri.pathSegments.last;
      return SourceResponse(
        statusCode: 200,
        url: request.url,
        body: jsonEncode({
          'type': 'file',
          'name': name,
          'path': name,
          'encoding': 'base64',
          'content':
              '${base64.encode(utf8.encode(name == 'index.json' ? catalog : age))}\n',
        }),
      );
    });
    final sources = SourceRegistry(
      repository: SourceRepository(db),
      http: transport,
    );
    addTearDown(sources.dispose);
    final canonical = KazumiRepository(sources, allowPublicFallback: true);
    final entries = await canonical.load(KazumiRepository.defaultRepository);
    expect(entries, hasLength(18));
    await canonical.install(
      KazumiRepository.defaultRepository,
      entries.singleWhere((entry) => entry.name == 'AGE'),
    );
    final stored = (await sources.repository.byId(
      KazumiRule.idForName('AGE'),
    ))!;
    expect(stored.ruleText, age);
    expect(stored.repoUrl, KazumiRepository.defaultRepository);
    expect(transport.requests.map((request) => Uri.parse(request.url).host), [
      'raw.githubusercontent.com',
      'api.github.com',
      'raw.githubusercontent.com',
      'api.github.com',
    ]);
  });

  test('TLS failures and custom repository deadlines cannot change delivery routes', () async {
    for (final custom in [false, true]) {
      final transport = _SecureHttp(
        (request) async => throw DioException(
          requestOptions: RequestOptions(path: request.url),
          type: custom
              ? DioExceptionType.connectionTimeout
              : DioExceptionType.badCertificate,
        ),
      );
      final sources = SourceRegistry(
        repository: SourceRepository(db),
        http: transport,
      );
      addTearDown(sources.dispose);
      await expectLater(
        KazumiRepository(
          sources,
          allowPublicFallback: true,
        ).load(custom ? repoA : KazumiRepository.defaultRepository),
        throwsA(isA<DioException>()),
      );
      expect(transport.requests, hasLength(1));
    }
  });

  test(
    'body timeout without original request credential metadata fails closed',
    () async {
      final transport = _BodyTimeoutHttp();
      final sources = SourceRegistry(
        repository: SourceRepository(db),
        http: transport,
      );
      addTearDown(sources.dispose);
      await expectLater(
        KazumiRepository(
          sources,
          allowPublicFallback: true,
        ).load(KazumiRepository.defaultRepository),
        throwsA(isA<TimeoutException>()),
      );
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.url, KazumiRepository.defaultRepository);
      expect(transport.requests.single.headers['Cookie'], 'inherited-session');
    },
  );

  test('typed deadline with actual inherited credentials cannot recover to another host', () async {
    for (final header in ['Cookie', 'Authorization']) {
      final transport = _SecureHttp(
        (request) async => throw DioException(
          requestOptions: RequestOptions(
            path: request.url,
            headers: {header: 'private-session'},
          ),
          type: DioExceptionType.receiveTimeout,
        ),
      );
      final sources = SourceRegistry(
        repository: SourceRepository(db),
        http: transport,
      );
      addTearDown(sources.dispose);
      await expectLater(
        KazumiRepository(
          sources,
          allowPublicFallback: true,
        ).load(KazumiRepository.defaultRepository),
        throwsA(isA<DioException>()),
      );
      expect(transport.requests, hasLength(1));
    }
  });

  test('canonical fallback rejects another file identity rather than accepting its catalog', () async {
    final transport = _SecureHttp((request) async {
      if (Uri.parse(request.url).host == 'raw.githubusercontent.com') {
        throw DioException(
          requestOptions: RequestOptions(path: request.url),
          type: DioExceptionType.receiveTimeout,
        );
      }
      return SourceResponse(
        statusCode: 200,
        url: request.url,
        body: jsonEncode({
          'type': 'file',
          'name': 'another.json',
          'path': 'another.json',
          'encoding': 'base64',
          'content': base64.encode(utf8.encode('[]')),
        }),
      );
    });
    final sources = SourceRegistry(
      repository: SourceRepository(db),
      http: transport,
    );
    addTearDown(sources.dispose);
    await expectLater(
      KazumiRepository(
        sources,
        allowPublicFallback: true,
      ).load(KazumiRepository.defaultRepository),
      throwsFormatException,
    );
  });

  test('batch refreshes every installed origin and preserves failures, disablement and removals', () async {
    final alpha = await install('alpha', repoA);
    final beta = await install('beta', repoB);
    final broken = await install('broken', repoA);
    final removed = await install('removed', repoA);
    await registry.setEnabled(alpha, enabled: false);
    final beforeBroken = await registry.repository.byId(broken);
    await registry.remove(removed);
    versions.addAll({
      'alpha': '1.1',
      'beta': '1.2',
      'broken': '1.3',
      'removed': '1.4',
    });
    failures.add('broken');
    http.requests.clear();
    final results = await client.refreshInstalled(
      repositories: {repoA: true, repoB: true},
      update: true,
    );
    expect(results.where((r) => r.updated).map((r) => r.id).toSet(), {
      alpha,
      beta,
    });
    expect(results.singleWhere((r) => r.id == broken).failed, isTrue);
    expect((await registry.repository.byId(alpha))!.enabled, isFalse);
    expect((await registry.repository.byId(alpha))!.version, '1.1');
    expect((await registry.repository.byId(beta))!.version, '1.2');
    expect(await registry.repository.byId(broken), beforeBroken);
    expect(await registry.repository.byId(removed), isNull);
    expect(http.requests.where((r) => r.url == repoA), hasLength(1));
    expect(http.requests.where((r) => r.url == repoB), hasLength(1));
    expect(
      http.requests.where((r) => r.url.endsWith('/removed.json')),
      isEmpty,
    );
  });

  test('same-version mutation and cross-origin replacement cannot change old bytes or trust', () async {
    final id = await install('alpha', repoA);
    await registry.setEnabled(id, enabled: false);
    final old = await registry.repository.byId(id);
    changedSameVersion = true;
    final results = await client.refreshInstalled(
      repositories: {repoA: true},
      update: true,
    );
    expect(results.single.failed, isTrue);
    expect(await registry.repository.byId(id), old);
    versions['alpha'] = '2.0';
    await expectLater(
      client.install(
        repoB,
        const KazumiCatalogEntry(name: 'alpha', version: '2.0'),
      ),
      throwsStateError,
    );
    expect(await registry.repository.byId(id), old);
  });

  test(
    'manual rules and disabled repositories are not silently trusted',
    () async {
      final id = await install('alpha', repoA);
      final old = (await registry.repository.byId(id))!;
      await registry.repository.upsert(
        id: old.id,
        name: old.name,
        type: MediaType.anime,
        kind: SourceKind.plugin,
        ruleText: old.ruleText,
        version: old.version,
        repoUrl: 'manual',
        enabled: false,
      );
      await install('beta', repoB);
      final manual = await registry.repository.byId(id);
      http.requests.clear();
      final results = await client.refreshInstalled(
        repositories: {repoA: true, repoB: false},
        update: true,
      );
      expect(results.every((r) => r.failed), isTrue);
      expect(http.requests, isEmpty);
      expect(await registry.repository.byId(id), manual);
    },
  );

  test('same-version whitespace and recursive object key order preserve installed bytes and enablement', () async {
    final raw = {
      ..._rule('alpha', '1.0'),
      'antiCrawlerConfig': {
        'enabled': false,
        'captchaDetectType': 1,
        'captchaDetectValue': '//form',
      },
      'preservedUpstreamMetadata': {
        'labels': ['one', 'two'],
        'optional': null,
      },
    };
    var text = jsonEncode(raw);
    final transport = _SecureHttp(
      (request) async =>
          SourceResponse(statusCode: 200, url: request.url, body: text),
    );
    final sources = SourceRegistry(
      repository: SourceRepository(db),
      http: transport,
    );
    addTearDown(sources.dispose);
    final installer = KazumiRepository(sources);
    const entry = KazumiCatalogEntry(name: 'alpha', version: '1.0');
    final descriptor = await installer.install(repoA, entry);
    await sources.setEnabled(descriptor.id, enabled: false);
    final before = await sources.repository.byId(descriptor.id);
    Object? reverseKeys(Object? value) {
      if (value is Map) {
        return {
          for (final key in value.keys.toList().reversed)
            key: reverseKeys(value[key]),
        };
      }
      if (value is List) return value.map(reverseKeys).toList();
      return value;
    }

    text = const JsonEncoder.withIndent('  ')
        .convert(reverseKeys(raw))
        .replaceAll('\n', '\r\n');
    await installer.install(repoA, entry);
    expect(await sources.repository.byId(descriptor.id), before);
    expect(
      (await sources.repository.byId(descriptor.id))!.ruleText,
      jsonEncode(raw),
    );

    // Reordering map keys is harmless; changing any value, type, missing key
    // or ordered array is not, even for retained upstream metadata.
    final mutations = <void Function(Map<String, dynamic>)>[
      (rule) => rule['antiCrawlerConfig']['captchaDetectValue'] = '//other',
      (rule) => rule['antiCrawlerConfig']['enabled'] = 'false',
      (rule) => rule['antiCrawlerConfig']['captchaDetectType'] = 1.0,
      (rule) => rule['preservedUpstreamMetadata']['labels'] = ['two', 'one'],
      (rule) => rule['preservedUpstreamMetadata'].remove('optional'),
    ];
    for (final mutate in mutations) {
      final changed = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
      mutate(changed);
      text = jsonEncode(changed);
      await expectLater(installer.install(repoA, entry), throwsStateError);
      expect(await sources.repository.byId(descriptor.id), before);
    }
  });

  for (final duringCatalog in [false, true]) {
    test(
      'removing during ${duringCatalog ? 'catalog' : 'rule'} download cannot resurrect source',
      () async {
        final id = await install('alpha', repoA);
        versions['alpha'] = '1.1';
        final started = Completer<void>(), release = Completer<void>();
        beforeResponse = (request) async {
          if (request.url.endsWith(
            duringCatalog ? '/index.json' : '/alpha.json',
          )) {
            if (!started.isCompleted) started.complete();
            await release.future;
          }
        };
        final updating = client.refreshInstalled(
          repositories: {repoA: true},
          update: true,
        );
        await started.future;
        await registry.remove(id);
        release.complete();
        final results = await updating;
        expect(results.single.failed, isTrue);
        expect(await registry.repository.byId(id), isNull);
      },
    );
  }

  test(
    'enablement change during download wins over in-flight replacement',
    () async {
      final id = await install('alpha', repoA);
      versions['alpha'] = '1.1';
      final started = Completer<void>(), release = Completer<void>();
      beforeResponse = (request) async {
        if (request.url.endsWith('/alpha.json')) {
          started.complete();
          await release.future;
        }
      };
      final updating = client.refreshInstalled(
        repositories: {repoA: true},
        update: true,
      );
      await started.future;
      await registry.setEnabled(id, enabled: false);
      release.complete();
      expect((await updating).single.failed, isTrue);
      final row = (await registry.repository.byId(id))!;
      expect(row.version, '1.0');
      expect(row.enabled, isFalse);
    },
  );

  test(
    'explicit install-all uses refreshed catalog and only adds missing plugins',
    () async {
      final id = await install('alpha', repoA);
      await registry.setEnabled(id, enabled: false);
      final existing = await registry.repository.byId(id);
      versions['alpha'] = '2.0';
      final results = await client.installMissing(repoA);
      expect(results.map((r) => r.name).toSet(), {'broken', 'removed'});
      expect(results.every((r) => r.updated), isTrue);
      expect(await registry.repository.byId(id), existing);
    },
  );

  test('actual mutefun self anchor resolves href and keeps independent episode roads', () async {
    final parsed = KazumiRule.parse(
      await rootBundle.loadString('assets/rules/kazumi-mutefun.json'),
    );
    final source = KazumiSource(
      rule: parsed,
      http: routingHttpClient({
        '/search':
            '<section class="search-results-section">'
            '<a class="video-card" href="/anime/one"><span class="video-card-title">One</span></a>'
            '<a class="video-card" href="/anime/two"><span class="video-card-title">Two</span></a></section>',
        '/anime/one':
            '<div class="episode-panel">'
            '<div class="episode-list"><a href="/play/1">第1集</a><a href="/play/2">第2集</a></div>'
            '<div class="episode-list"><a href="/other/1">第1集</a></div></div>',
      }),
    );
    final items = await source.search('one');
    expect(items.map((item) => item.title), ['One', 'Two']);
    expect(items.map((item) => item.url), [
      'https://www.mutedm.com/anime/one',
      'https://www.mutedm.com/anime/two',
    ]);
    final chapters = await source.chapters(items.first);
    expect(chapters.map((chapter) => chapter.url), [
      'https://www.mutedm.com/play/1',
      'https://www.mutedm.com/play/2',
      'https://www.mutedm.com/other/1',
    ]);
    expect(chapters.map((chapter) => chapter.volumeTitle), [
      '播放列表 1',
      '播放列表 1',
      '播放列表 2',
    ]);
  });

  test('actual mutefun captcha is reported for manual verification without a solver request', () async {
    final parsed = KazumiRule.parse(
      await rootBundle.loadString('assets/rules/kazumi-mutefun.json'),
    );
    final site = routingHttpClient({
      '/search': '<form action="/captcha/verify"><img src="/captcha"><input id="gate-answer"></form>',
    });
    final source = KazumiSource(rule: parsed, http: site);
    await expectLater(
      source.search('one'),
      throwsA(isA<KazumiVerificationRequired>()),
    );
    expect(site.requests, hasLength(1));
    expect(site.requests.single.method, 'GET');
  });
}
