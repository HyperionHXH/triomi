import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/kazumi_repository.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/kazumi_repositories_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

Map<String, Object?> _definition(
  String name, {
  bool archived = true,
  String version = '1.0',
}) => {
  'api': '4',
  'name': name,
  'version': version,
  if (archived) 'deprecated': true,
  'type': 'anime',
  'baseURL': 'https://anime.test/',
  'searchURL': 'https://anime.test/search?q=@keyword',
  'searchList': '//li',
  'searchName': '//a',
  'searchResult': '//a',
  'chapterRoads': '//ul',
  'chapterResult': '//li/a',
};

class _ArchiveHttp extends FakeHttpClient implements SecureRuleDownloadClient {
  _ArchiveHttp(super.handler);
  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) => downloadBytes(url, sourceId: sourceId);
}

class _GatedArchiveHttp extends FakeHttpClient
    implements SecureRuleDownloadClient {
  _GatedArchiveHttp(this.names, {this.indexGate})
    : super((_) async => throw StateError('Only secure streams are expected'));

  final List<String> names;
  final gates = <String, Completer<List<int>>>{};
  final started = <String>[];
  final firstWave = Completer<void>();
  final Completer<List<int>>? indexGate;
  final indexStarted = Completer<void>();
  var inFlight = 0, maxInFlight = 0;
  bool releaseRemaining = false;

  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) async {
    requests.add(SourceRequest(url: url));
    final uri = Uri.parse(url);
    if (uri.host == 'api.github.com') {
      return SourceByteStream(
        url: url,
        stream: Stream.value(
          utf8.encode(
            jsonEncode([
              for (final name in names) {'name': '$name.json', 'type': 'file'},
            ]),
          ),
        ),
      );
    }
    if (uri.pathSegments.last == 'index.json') {
      if (!indexStarted.isCompleted) indexStarted.complete();
      return SourceByteStream(
        url: url,
        stream: indexGate == null
            ? Stream.value(utf8.encode('[]'))
            : Stream.fromFuture(indexGate!.future),
      );
    }
    final name = uri.pathSegments.last.replaceFirst('.json', '');
    return SourceByteStream(url: url, stream: _body(name));
  }

  Stream<List<int>> _body(String name) async* {
    started.add(name);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final gate = gates[name] = Completer<List<int>>();
    if (started.length == names.length.clamp(0, 4)) firstWave.complete();
    if (releaseRemaining) release(name);
    try {
      yield await gate.future;
    } finally {
      inFlight--;
    }
  }

  void release(String name, {bool fail = false}) {
    final gate = gates[name]!;
    if (gate.isCompleted) return;
    if (fail) {
      gate.completeError(StateError('bounded archive response failed'));
    } else {
      gate.complete(utf8.encode(jsonEncode(_definition(name))));
    }
  }

  void finishAll() {
    if (indexGate?.isCompleted == false) indexGate!.complete(utf8.encode('[]'));
    releaseRemaining = true;
    for (final name in gates.keys.toList()) {
      release(name);
    }
  }
}

Future<void> _pumpArchiveIo(WidgetTester tester) async {
  for (var round = 0; round < 6; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

class _ArchiveSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() =>
      ref.read(sourceRegistryProvider).load();
}

// Alternate real I/O and the owning FakeAsync callbacks, with a finite barrier.
Future<void> _settleArchiveIo(
  WidgetTester tester, {
  bool Function()? until,
}) async {
  for (var round = 0;
      round < (until == null ? 12 : 300) && !(until?.call() ?? false);
      round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  if (until != null) {
    expect(until(), isTrue, reason: 'Archived UI must reach its expected state');
  }
}

Future<T> _finishArchiveOwned<T>(WidgetTester tester, Future<T> pending) async {
  var finished = false;
  late T result;
  Object? failure;
  StackTrace? trace;
  unawaited(pending.then((value) {
    result = value;
    finished = true;
  }, onError: (Object error, StackTrace stack) {
    failure = error;
    trace = stack;
    finished = true;
  }));
  for (var attempt = 0; attempt < 300 && !finished; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(finished, isTrue, reason: 'Archive operation must reach its barrier');
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late SourceRegistry registry;
  late KazumiRepository client;
  late _ArchiveHttp http;
  var databaseClosed = false;
  var version = '1.0';
  final broken = <String>{};
  setUp(() {
    databaseClosed = false;
    db = openTestDatabase();
    version = '1.0';
    broken.clear();
    http = _ArchiveHttp((request) async {
      final uri = Uri.parse(request.url);
      Object body;
      if (uri.host == 'api.github.com') {
        body = [
          for (final name in [
            'index',
            'active',
            'xfdm',
            'anime7',
            'futureArchived',
            'bad',
          ])
            {'name': '$name.json', 'path': '$name.json', 'type': 'file'},
          {'name': 'ignore.txt', 'type': 'file'},
          {'name': 'folder.json', 'type': 'dir'},
        ];
      } else {
        final name = uri.pathSegments.last.replaceFirst('.json', '');
        if (broken.contains(name)) throw StateError('anonymous request failed');
        body = name == 'index'
            ? [
                {'name': 'active', 'version': '1.0'},
              ]
            : name == 'bad'
            ? {'deprecated': true, 'name': 'mismatch'}
            : _definition(name, archived: name != 'active', version: version);
      }
      return SourceResponse(
        statusCode: 200,
        url: request.url,
        body: jsonEncode(body),
      );
    });
    registry = SourceRegistry(repository: SourceRepository(db), http: http);
    client = KazumiRepository(registry);
  });
  tearDown(() async {
    registry.dispose();
    if (!databaseClosed) await db.close();
  });

  Future<void> closeWidget(
    WidgetTester tester,
    ProviderContainer container, {
    _GatedArchiveHttp? transport,
    SourceRegistry? extraRegistry,
  }) async {
    // Unmount first so generation cancellation wins over late gated responses.
    await tester.pumpWidget(const SizedBox.shrink());
    transport?.finishAll();
    await _settleArchiveIo(tester, until: transport == null
        ? null
        : () => transport.inFlight == 0);
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await _pumpArchiveIo(tester);
    extraRegistry?.dispose();
    registry.dispose();
    await tester.runAsync(() => db.close().timeout(const Duration(seconds: 5)));
    databaseClosed = true;
  }

  test('official archive uses actual upstream files, separates active catalog and exposes failures', () async {
    final active = await client.load(KazumiRepository.defaultRepository);
    expect(active.map((entry) => entry.name), ['active']);
    final archive = await client.loadArchived(
      KazumiRepository.defaultRepository,
    );
    expect(archive.entries.map((entry) => entry.name).toSet(), {
      'xfdm',
      'anime7',
      'futureArchived',
    });
    expect(archive.entries.every((entry) => entry.archived), isTrue);
    expect(archive.failures.single, contains('bad'));
    expect(
      http.requests.any((request) => request.url.endsWith('/active.json')),
      isFalse,
    );
    expect(await registry.repository.count(), 0);
    expect(
      http.requests.every(
        (request) => [
          'raw.githubusercontent.com',
          'api.github.com',
        ].contains(Uri.parse(request.url).host),
      ),
      isTrue,
    );
    await expectLater(
      client.loadArchived('https://custom.test/index.json'),
      throwsStateError,
    );
  });

  test('deprecated rule requires explicit opt-in and preserves bytes origin and disabled state across restart', () async {
    final text = jsonEncode(_definition('xfdm'));
    expect(() => KazumiRule.parse(text), throwsA(isA<Exception>()));
    await expectLater(registry.importFromText(text), throwsA(isA<Exception>()));
    await client.installLatest(
      KazumiRepository.defaultRepository,
      'xfdm',
      archived: true,
    );
    final id = KazumiRule.idForName('xfdm');
    final saved = (await registry.repository.byId(id))!;
    expect(saved.ruleText, text);
    expect(saved.repoUrl, KazumiRepository.defaultRepository);
    expect(saved.enabled, isFalse);
    final snapshot = await registry.load();
    expect(snapshot.failures, isEmpty);
    final entry = snapshot.manageableEntries.singleWhere(
      (entry) => entry.descriptor.id == id,
    );
    expect((entry.source as KazumiSource).rule.deprecated, isTrue);
    await registry.setEnabled(id, enabled: true);
    version = '1.1';
    await client.refreshInstalled(
      repositories: {KazumiRepository.defaultRepository: true},
      update: true,
    );
    expect((await registry.repository.byId(id))!.version, '1.1');
    expect((await registry.repository.byId(id))!.enabled, isTrue);
  });

  test('archive cannot overwrite custom rules and explicit import never reinstalls removals through refresh', () async {
    final text = jsonEncode(_definition('xfdm'));
    await registry.importFromText(text, allowDeprecated: true);
    final id = KazumiRule.idForName('xfdm');
    final saved = await registry.repository.byId(id);
    await expectLater(
      client.installLatest(
        KazumiRepository.defaultRepository,
        'xfdm',
        archived: true,
      ),
      throwsStateError,
    );
    expect(await registry.repository.byId(id), saved);
    await registry.remove(id);
    await client.refreshInstalled(
      repositories: {KazumiRepository.defaultRepository: true},
      update: true,
    );
    expect(await registry.repository.byId(id), isNull);
    await client.installMissing(KazumiRepository.defaultRepository);
    expect(await registry.repository.byId(id), isNull);
  });

  test('retained archived anime7 full backup previews and restores disabled without credential exemption', () async {
    final support = await Directory.systemTemp.createTemp(
      'archived-rule-backup-',
    );
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => support.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null);
      await support.delete(recursive: true);
    });
    await client.installLatest(
      KazumiRepository.defaultRepository,
      'anime7',
      archived: true,
    );
    final id = KazumiRule.idForName('anime7');
    final original = (await registry.repository.byId(id))!;
    expect(original.enabled, isFalse);
    expect(
      KazumiRule.parse(original.ruleText!, allowDeprecated: true).deprecated,
      isTrue,
    );
    final exporter = BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: http,
    );
    final backup = await exporter.exportToFile(
      includeCovers: false,
      includeSourceRules: true,
    );
    final target = openTestDatabase();
    addTearDown(target.close);
    final preview = await previewBackupRestoreFile(target, backup.path);
    expect(preview.incomingSourceRules, 1);
    final imported =
        await BackupService(
          database: target,
          preferences: memoryPreferences(),
          http: http,
        ).importFromFile(
          backup.path,
          options: const BackupRestoreOptions(restoreSourceRules: true),
          expectedHash: preview.byteHash,
        );
    expect(imported.sourceRules, 1);
    final restored = (await SourceRepository(target).byId(id))!;
    expect(restored.ruleText, original.ruleText);
    expect(restored.repoUrl, original.repoUrl);
    expect(restored.enabled, isFalse);
    final restarted = SourceRegistry(
      repository: SourceRepository(target),
      http: http,
    );
    addTearDown(restarted.dispose);
    final snapshot = await restarted.load();
    expect(snapshot.failures, isEmpty);
    final entry = snapshot.entries.singleWhere(
      (entry) => entry.descriptor.id == id,
    );
    expect(entry.enabled, isFalse);
    expect((entry.source as KazumiSource).rule.deprecated, isTrue);

    final payload = BackupService.validatedPayload(
      await File(backup.path).readAsBytes(),
    );
    for (final header in ['Authorization', 'Cookie']) {
      final forged = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      final definition = (forged['sourceRuleDefinitions'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((row) => row['id'] == id);
      final rule =
          jsonDecode(definition['ruleText'] as String) as Map<String, dynamic>;
      rule['headers'] = {header: 'private-user-credential'};
      definition['ruleText'] = jsonEncode(rule);
      expect(() => BackupService.sourceRulesOf(forged), throwsFormatException);
    }
    final privateRule = jsonDecode(original.ruleText!) as Map<String, dynamic>;
    privateRule['headers'] = {'Authorization': 'Bearer private-user-token'};
    await registry.repository.upsert(
      id: original.id,
      name: original.name,
      type: original.type,
      kind: original.kind,
      ruleText: jsonEncode(privateRule),
      version: original.version,
      repoUrl: original.repoUrl,
      enabled: false,
    );
    await expectLater(
      exporter.exportToFile(includeCovers: false, includeSourceRules: true),
      throwsFormatException,
    );
  });

  test('archive progress reports first verified rule and failure before other streams finish with at most four in flight', () async {
    final transport = _GatedArchiveHttp([
      for (var i = 0; i < 8; i++) 'archive0$i',
    ]);
    final sources = SourceRegistry(
      repository: SourceRepository(db),
      http: transport,
    );
    addTearDown(sources.dispose);
    final events = <(String?, String?, int, int)>[];
    final first = Completer<void>(), failed = Completer<void>();
    var finished = false;
    final loading = KazumiRepository(sources)
        .loadArchived(
          KazumiRepository.defaultRepository,
          onProgress: (entry, failure, completed, total) {
            events.add((entry?.name, failure, completed, total));
            if (entry?.name == 'archive00') first.complete();
            if (failure != null) failed.complete();
          },
        )
        .then((result) {
          finished = true;
          return result;
        });
    try {
    await transport.firstWave.future;
    expect(transport.started, [
      'archive00',
      'archive01',
      'archive02',
      'archive03',
    ]);
    expect(transport.maxInFlight, 4);
    transport.release('archive00');
    await first.future;
    expect(finished, isFalse);
    expect(events.single, ('archive00', null, 1, 8));
    expect(transport.gates['archive02']!.isCompleted, isFalse);
    transport.release('archive01', fail: true);
    await failed.future;
    expect(finished, isFalse);
    expect(events.last.$2, contains('archive01'));
    expect(events.last.$3, 2);
    expect(events.last.$4, 8);
    transport.finishAll();
    final result = await loading;
    expect(result.entries, hasLength(7));
    expect(result.failures.single, contains('archive01'));
    expect(
      events.map((event) => event.$3),
      orderedEquals([1, 2, 3, 4, 5, 6, 7, 8]),
    );
    expect(transport.maxInFlight, 4);
    expect(transport.inFlight, 0);
    } finally {
      transport.finishAll();
      await loading;
    }
  });

  test('initially cancelled archive load sends no requests or callbacks', () async {
    final transport = _GatedArchiveHttp(['archive00']);
    final sources = SourceRegistry(repository: SourceRepository(db), http: transport);
    addTearDown(sources.dispose);
    var callbacks = 0;
    final result = await KazumiRepository(sources).loadArchived(
      KazumiRepository.defaultRepository,
      isCancelled: () => true,
      onProgress: (_, failure, completed, total) => callbacks++,
    );
    expect(result.entries, isEmpty);
    expect(result.failures, isEmpty);
    expect(transport.requests, isEmpty);
    expect(transport.started, isEmpty);
    expect(callbacks, 0);
  });

  test('cancellation while active index is gated never requests contents or archive bodies', () async {
    final indexGate = Completer<List<int>>();
    final transport = _GatedArchiveHttp(['archive00'], indexGate: indexGate);
    final sources = SourceRegistry(repository: SourceRepository(db), http: transport);
    addTearDown(sources.dispose);
    var cancelled = false, callbacks = 0;
    final loading = KazumiRepository(sources).loadArchived(
      KazumiRepository.defaultRepository,
      isCancelled: () => cancelled,
      onProgress: (_, failure, completed, total) => callbacks++,
    );
    try {
    await transport.indexStarted.future;
    expect(transport.requests.single.url, KazumiRepository.defaultRepository);
    cancelled = true;
    indexGate.complete(utf8.encode('[]'));
    final result = await loading;
    expect(result.entries, isEmpty);
    expect(result.failures, isEmpty);
    expect(transport.requests, hasLength(1));
    expect(transport.requests.any((request) => Uri.parse(request.url).host == 'api.github.com'), isFalse);
    expect(transport.started, isEmpty);
    expect(callbacks, 0);
    } finally {
      cancelled = true;
      transport.finishAll();
      await loading;
    }
  });

  test('archive cancellation stops scheduling queued files and suppresses callbacks from the four in-flight streams', () async {
    final transport = _GatedArchiveHttp([
      for (var i = 0; i < 8; i++) 'archive0$i',
    ]);
    final sources = SourceRegistry(
      repository: SourceRepository(db),
      http: transport,
    );
    addTearDown(sources.dispose);
    var cancelled = false;
    final first = Completer<void>();
    final callbacks = <String?>[];
    final loading = KazumiRepository(sources).loadArchived(
      KazumiRepository.defaultRepository,
      isCancelled: () => cancelled,
      onProgress: (entry, failure, completed, total) {
        callbacks.add(entry?.name);
        cancelled = true;
        first.complete();
      },
    );
    try {
    await transport.firstWave.future;
    transport.release('archive00');
    await first.future;
    expect(callbacks, ['archive00']);
    transport.release('archive01', fail: true);
    transport.finishAll();
    await loading;
    expect(transport.started, [
      'archive00',
      'archive01',
      'archive02',
      'archive03',
    ]);
    expect(callbacks, ['archive00']);
    expect(transport.maxInFlight, 4);
    expect(transport.inFlight, 0);
    } finally {
      cancelled = true;
      transport.finishAll();
      await loading;
    }
  });

  testWidgets(
    'verified archived card and failure progress appear while other secure response bodies remain gated',
    (tester) async {
      final transport = _GatedArchiveHttp([
        'archive00',
        'archive01',
        'archive02',
        'archive03',
      ]);
      final sources = SourceRegistry(
        repository: SourceRepository(db),
        http: transport,
      );
      final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(memoryPreferences()),
            sourceRegistryProvider.overrideWithValue(sources),
            sourcesProvider.overrideWith(_ArchiveSources.new),
          ],
      );
      try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: KazumiRepositoriesSheet()),
          ),
        ),
      );
      await _settleArchiveIo(tester, until: () =>
          find.byType(CircularProgressIndicator).evaluate().isEmpty);
      await tester.tap(find.text('已归档规则'));
      await _finishArchiveOwned(tester, transport.firstWave.future);
      transport.release('archive00');
      transport.release('archive01', fail: true);
      await _settleArchiveIo(tester, until: () =>
          find.text('归档逐项核对 2 / 4 · 已显示 1 条').evaluate().isNotEmpty);
      await tester.scrollUntilVisible(
        find.text('archive00'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('archive00'), findsOneWidget);
      expect(find.text('归档读取失败 1 项 · 未隐藏失败'), findsOneWidget);
      expect(find.text('归档逐项核对 2 / 4 · 已显示 1 条'), findsOneWidget);
      expect(transport.gates['archive02']!.isCompleted, isFalse);
      expect(transport.gates['archive03']!.isCompleted, isFalse);
      expect(transport.maxInFlight, 4);
      await tester.ensureVisible(find.text('归档读取失败 1 项 · 未隐藏失败'));
      await tester.tap(find.text('归档读取失败 1 项 · 未隐藏失败'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('archive01：'), findsOneWidget);
      } finally {
        await closeWidget(tester, container, transport: transport, extraRegistry: sources);
      }
      expect(transport.inFlight, 0);
    },
  );

  testWidgets('current-rule selector remains usable during archived streams and late archive results cannot repaint it', (tester) async {
    final transport = _GatedArchiveHttp([for (var i = 0; i < 8; i++) 'archive0$i']);
    final sources = SourceRegistry(repository: SourceRepository(db), http: transport);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourceRegistryProvider.overrideWithValue(sources),
        sourcesProvider.overrideWith(_ArchiveSources.new),
      ],
    );
    try {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: KazumiRepositoriesSheet())),
    ));
    await _settleArchiveIo(tester, until: () =>
        find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await tester.tap(find.text('已归档规则'));
    await _finishArchiveOwned(tester, transport.firstWave.future);
    await tester.pump();
    expect(transport.started, ['archive00', 'archive01', 'archive02', 'archive03']);
    final selector = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>));
    expect(selector.onSelectionChanged, isNotNull);
    expect(selector.selected, {true});
    await tester.tap(find.text('当前规则'));
    await _settleArchiveIo(tester, until: () =>
        find.text('本仓库 0 个插件').evaluate().isNotEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>)).selected, {false});
    expect(find.text('本仓库 0 个插件'), findsOneWidget);
    expect(transport.gates['archive02']!.isCompleted, isFalse);
    transport.release('archive01', fail: true);
    transport.finishAll();
    await _pumpArchiveIo(tester);
    expect(transport.started, ['archive00', 'archive01', 'archive02', 'archive03']);
    expect(transport.inFlight, 0);
    expect(find.text('本仓库 0 个插件'), findsOneWidget);
    expect(find.textContaining('归档逐项核对'), findsNothing);
    expect(find.textContaining('归档读取失败'), findsNothing);
    for (final name in transport.names) {
      expect(find.text(name), findsNothing);
    }
    expect(await sources.repository.count(), 0);
    } finally {
      await closeWidget(tester, container, transport: transport, extraRegistry: sources);
    }
  });


  testWidgets(
    'archive is explicit, warned, individually imported and never part of install-all',
    (tester) async {
      final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(memoryPreferences()),
            sourceRegistryProvider.overrideWithValue(registry),
            sourcesProvider.overrideWith(_ArchiveSources.new),
          ],
      );
      try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: KazumiRepositoriesSheet()),
          ),
        ),
      );
      await _settleArchiveIo(tester, until: () => find.text('active').evaluate().isNotEmpty);
      expect(find.text('active'), findsOneWidget);
      expect(find.text('xfdm'), findsNothing);
      await tester.tap(find.text('已归档规则'));
      await _settleArchiveIo(tester, until: () =>
          find.text('官方归档 3 条规则').evaluate().isNotEmpty);
      expect(find.text('官方归档 3 条规则'), findsOneWidget);
      final installAll = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '安装本仓库未安装插件'),
      );
      expect(installAll.onPressed, isNull);
      await tester.scrollUntilVisible(
        find.text('xfdm'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await _settleArchiveIo(tester);
      final card = find.ancestor(
        of: find.text('xfdm'),
        matching: find.byType(Card),
      );
      final importButton = find.descendant(
        of: card,
        matching: find.text('导入归档规则'),
      );
      await tester.ensureVisible(importButton);
      await _settleArchiveIo(tester);
      await tester.tap(importButton);
      await _settleArchiveIo(tester);
      expect(find.textContaining('新安装保持停用'), findsWidgets);
      expect(
        await registry.repository.byId(KazumiRule.idForName('xfdm')),
        isNull,
      );
      await tester.tap(find.text('仍要导入'));
      await _settleArchiveIo(tester);
      await _finishArchiveOwned(tester, container.read(sourcesProvider.future));
      expect(
        (await registry.repository.byId(KazumiRule.idForName('xfdm')))!.enabled,
        isFalse,
      );
      } finally {
        await closeWidget(tester, container);
      }
    },
  );
}
