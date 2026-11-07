// Standalone Windows acceptance target; production main and user stores are not opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
// Existing path_provider dependency; only this acceptance target redirects its paths.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/main.dart' as production;

const _package = 'eu.kanade.tachiyomi.extension.zh.jinmantiantang';
const _signer =
    '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';
const _apkHash =
    'e30a1c09951a41cd486533112fdd220187f60f0c6165599a6ac2285454e3cfd0';
const _jarHash =
    '5eebd0bae530be491fe1cae32d1940c3914b224c46e7b9d6dd596415ef2c8be7';
const _defaultBase =
    'https://github.com/keiyoushi/extensions/releases/download/4591fbc-2';

String _option(String key, String defined, [String fallback = '']) =>
    defined.isNotEmpty ? defined : Platform.environment[key] ?? fallback;

void _require(bool condition, String code) {
  if (!condition) throw StateError(code);
}

@pragma('vm:entry-point')
Future<void> jsWorker([List<String> args = const []]) =>
    production.jsWorker(args);

class _AcceptancePaths extends PathProviderPlatform {
  _AcceptancePaths(this.root);
  final Directory root;

  Future<String> _child(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationSupportPath() => _child('support');
  @override
  Future<String?> getApplicationDocumentsPath() => _child('documents');
  @override
  Future<String?> getApplicationCachePath() => _child('cache');
  @override
  Future<String?> getTemporaryPath() => _child('temporary');
  @override
  Future<String?> getDownloadsPath() => _child('downloads');
}

/// Only installer artifact delivery may read the exact fingerprinted local files.
/// Source website requests still use the production HTTP client and JVM network.
class _LocalArtifacts extends SourceHttpClient {
  _LocalArtifacts(this.delegate, this.files);
  final SourceHttpClient delegate;
  final Map<String, File> files;

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    final file = files[url];
    if (file != null) {
      return SourceByteStream(
        stream: file.openRead(),
        url: url,
        contentLength: await file.length(),
      );
    }
    if (delegate case final SecureRuleDownloadClient secure) {
      return secure.downloadRuleBytes(url, sourceId: sourceId);
    }
    return delegate.downloadBytes(
      url,
      sourceId: sourceId,
      headers: headers,
      followRedirects: followRedirects,
    );
  }

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) => delegate.send(request, sourceId: sourceId);
  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) => delegate.fetchBytes(
    url,
    sourceId: sourceId,
    headers: headers,
    method: method,
  );
  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const {},
    String method = 'PUT',
  }) => delegate.uploadBytes(
    url,
    sourceId: sourceId,
    bytes: bytes,
    headers: headers,
    method: method,
  );
  @override
  void close() => delegate.close();
}

List<Element> _elements(bool Function(Widget) matches) {
  final result = <Element>[];
  void visit(Element element) {
    if (matches(element.widget)) result.add(element);
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return result;
}

Future<void> _until(
  bool Function() ready,
  String failure, {
  int seconds = 90,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready()) {
    _require(DateTime.now().isBefore(deadline), failure);
    WidgetsBinding.instance.scheduleForcedFrame();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<Directory> _newRoot() async {
  final value = _option(
    'TRIOMI_ACCEPTANCE_ROOT',
    const String.fromEnvironment('TRIOMI_ACCEPTANCE_ROOT'),
  );
  _require(p.isAbsolute(value), 'acceptance_root_must_be_absolute');
  final allowed = await Directory('D:/noval_and_manga/_tools/jm-apk-debug')
      .resolveSymbolicLinks();
  final parent = await Directory(p.dirname(p.normalize(value)))
      .resolveSymbolicLinks();
  final root = p.join(parent, p.basename(p.normalize(value)));
  _require(
    p.isWithin(allowed.toLowerCase(), root.toLowerCase()),
    'acceptance_root_outside_workspace',
  );
  _require(
    p.basename(root).startsWith('windows-flutter-acceptance-'),
    'acceptance_root_name_invalid',
  );
  _require(
    await FileSystemEntity.type(root, followLinks: false) ==
        FileSystemEntityType.notFound,
    'acceptance_root_must_be_new',
  );
  return Directory(root).create();
}

Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--triomi-js-worker') {
    await jsWorker(args);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  Directory? root;
  ProviderContainer? container;
  AppDatabase? database;
  var succeeded = false;
  final record = <String, Object?>{
    'format': 1,
    'platform': 'windows',
    'status': 'running',
    'stage': 'isolation',
  };
  Future<void> publish(String stage) async {
    record['stage'] = stage;
    await File(p.join(root!.path, 'evidence.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(record),
      flush: true,
    );
    debugPrint('WINDOWS_MIHON_ACCEPTANCE ${jsonEncode(record)}');
  }

  try {
    _require(Platform.isWindows, 'windows_only_acceptance');
    root = await _newRoot();
    final nativeMode = await const MethodChannel('triomi/platform')
        .invokeMapMethod<String, Object?>('desktopMihonAcceptanceDiagnostics');
    record['nativeAcceptance'] = nativeMode;
    _require(
      nativeMode?['isolatedBuild'] == true,
      'isolated_native_build_required',
    );
    PathProviderPlatform.instance = _AcceptancePaths(root);
    final runtimeSettings = await Directory(
      p.join(root.path, 'support', 'mihon-desktop', 'settings'),
    ).create(recursive: true);
    // An empty acceptance root has no legacy Java-registry settings to import.
    // Match the runtime build smoke test without reading the user's old prefs.
    await File(p.join(runtimeSettings.path, 'migrations.xml')).writeAsString(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">\n'
      '<properties><entry key="version">3</entry></properties>\n',
    );
    final hive = await Directory(p.join(root.path, 'hive')).create();
    Hive.init(hive.path);
    final preferences = await Preferences.open();
    await preferences.set('setup.onboarding.state', 'complete');
    await preferences.set(Preferences.automaticAppUpdateCheckKey, false);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        databaseProvider.overrideWithValue(database),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
      ],
    );
    final boundary = GlobalKey();
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: boundary, child: const TriomiApp()),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    record['isolation'] = {
      'newDataRoot': true,
      'pathProviderRedirected': true,
      'hiveIsolated': true,
      'database': 'memory',
      'secureStore': 'memory',
      'sourceHttp': 'production',
      'hostChannel': 'production',
      'legacyPreferenceMigration': 'skipped for empty acceptance root',
    };
    await publish('artifacts');
    final apkUrl = _option(
      'TRIOMI_MIHON_APK_URL',
      const String.fromEnvironment('TRIOMI_MIHON_APK_URL'),
      '$_defaultBase/tachiyomi-zh.jinmantiantang-v1.6.64.apk',
    );
    final jarUrl = _option(
      'TRIOMI_MIHON_JAR_URL',
      const String.fromEnvironment('TRIOMI_MIHON_JAR_URL'),
      '$_defaultBase/tachiyomi-zh.jinmantiantang-v1.6.64.jar',
    );
    final localPaths = {
      apkUrl: (
        _option(
          'TRIOMI_MIHON_APK_PATH',
          const String.fromEnvironment('TRIOMI_MIHON_APK_PATH'),
        ),
        _apkHash,
      ),
      jarUrl: (
        _option(
          'TRIOMI_MIHON_JAR_PATH',
          const String.fromEnvironment('TRIOMI_MIHON_JAR_PATH'),
        ),
        _jarHash,
      ),
    };
    final localFiles = <String, File>{};
    for (final entry in localPaths.entries) {
      final (path, expected) = entry.value;
      if (path.isEmpty) continue;
      _require(p.isAbsolute(path), 'artifact_path_must_be_absolute');
      final file = File(path);
      _require(
        (await sha256.bind(file.openRead()).first).toString() == expected,
        'local_original_fingerprint_mismatch',
      );
      localFiles[entry.key] = file;
    }
    record['artifactDelivery'] = localFiles.isEmpty
        ? 'official HTTPS'
        : 'fingerprinted original local files; remaining files official HTTPS';
    final http = container.read(sourceHttpClientProvider);
    await publish('install');
    final installed =
        await MihonInstaller(
          http: localFiles.isEmpty ? http : _LocalArtifacts(http, localFiles),
          preferences: preferences,
        ).install(
          MihonExtension(
            name: 'Jinman',
            packageName: _package,
            apkUrl: apkUrl,
            iconUrl: '',
            extensionLib: '1.6',
            versionCode: 106064,
            versionName: '1.6.64',
            sources: [],
            apkSha256: _apkHash,
            jarUrl: jarUrl,
            jarSha256: _jarHash,
          ),
          signerSha256: _signer,
          confirmPublisher: (candidate) async {
            _require(
              candidate.packageName == _package &&
                  candidate.versionCode == 106064 &&
                  candidate.actualSigner == _signer &&
                  candidate.apkHash == _apkHash &&
                  candidate.desktopJarSha256 == _jarHash &&
                  !candidate.localApkConversion,
              'unapproved_artifact_identity',
            );
            record['fixedFingerprintsExplicitlyAccepted'] = true;
            return true;
          },
        );
    _require(
      installed['ok'] == true &&
          installed['executable'] == true &&
          installed['signatureVerified'] == true,
      'installation_not_executable',
    );
    _require(
      record['fixedFingerprintsExplicitlyAccepted'] == true,
      'publisher_confirmation_not_requested',
    );
    _require(
      installed['desktopCodeKind'] == 'nativeJar' &&
          installed['runtimeFileSha256'] == _jarHash,
      'unexpected_runtime_artifact',
    );
    record.addAll({
      'apkSha256': _apkHash,
      'jarSha256': _jarHash,
      'runtimeFileSha256': installed['runtimeFileSha256'],
      'sourceCount': installed['sourceCount'],
      'filterProbe': installed['filterProbe'],
    });
    _require(
      await platformChannel.setMihonEnabled(_package, true),
      'enable_failed',
    );
    await preferences.set('mihon.enabledPackages', [_package]);
    container.invalidate(sourceRegistryProvider);
    await container.read(sourcesProvider.notifier).refresh();
    final snapshot = await container.read(sourcesProvider.future);
    final source = snapshot.enabledEntries
        .map((entry) => entry.source)
        .whereType<MihonSource>()
        .firstWhere((source) => source.packageName == _package);
    await publish('search');
    final results = await source.search('test');
    _require(results.isNotEmpty, 'search_empty');
    record['searchCount'] = results.length;
    await publish('detail_and_pages');
    final item = await source.detail(results.first);
    final chapters = await source.chapters(item);
    _require(chapters.isNotEmpty, 'chapters_empty');
    final chapter = chapters.first;
    final library = container.read(libraryRepositoryProvider);
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: chapters,
    );
    final pages = await source.content(chapter, item: item);
    _require(pages.images.length > 3, 'insufficient_pages');
    record.addAll({
      'chapterCount': chapters.length,
      'pageCount': pages.images.length,
    });
    await publish('real_image_decode');
    final imageClient = HttpClient();
    try {
      final response = await (await imageClient.getUrl(
        Uri.parse(pages.images[3]),
      )).close();
      _require(response.statusCode == 200, 'image_http_failure');
      final bytes = await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      _require(
        frame.image.width > 100 && frame.image.height > 100,
        'image_dimensions_invalid',
      );
      record.addAll({
        'imageBytes': bytes.length,
        'imageWidth': frame.image.width,
        'imageHeight': frame.image.height,
      });
      frame.image.dispose();
      codec.dispose();
    } finally {
      imageClient.close(force: true);
    }
    await container
        .read(readerSettingsProvider.notifier)
        .setMode(ReadingMode.ltr);
    await publish('reader');
    unawaited(
      container
          .read(routerProvider)
          .push<void>(
            AppRoutes.reader,
            extra: MangaReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: 0,
            ),
          ),
    );
    await _until(
      () =>
          _elements((widget) => widget is MangaReaderPage).isNotEmpty &&
          _elements((widget) => widget is PageView).isNotEmpty,
      'reader_not_mounted',
    );
    final pageView =
        _elements((widget) => widget is PageView).first.widget as PageView;
    await _until(
      () => pageView.controller?.hasClients == true,
      'reader_controller_not_ready',
    );
    pageView.controller!.jumpToPage(3);
    await _until(
      () =>
          _elements(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_PagePainter',
          ).isNotEmpty &&
          pageView.controller!.page!.round() == 3,
      'reader_image_not_painted',
    );
    await _until(
      () =>
          boundary.currentContext?.findRenderObject() is RenderRepaintBoundary,
      'reader_frame_not_ready',
    );
    WidgetsBinding.instance.scheduleForcedFrame();
    await WidgetsBinding.instance.endOfFrame;
    final paint =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final screenshot = await paint.toImage(pixelRatio: 1);
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    await File(p.join(root.path, 'reader.png'))
        .writeAsBytes(png!.buffer.asUint8List(), flush: true);
    screenshot.dispose();
    record.addAll({
      'readerMounted': true,
      'readerPage': pageView.controller!.page!.round(),
      'readerImagePainted': true,
      'readerScreenshot': 'reader.png',
      'status': 'passed',
    });
    await publish('completed');
    succeeded = true;
    final hold =
        int.tryParse(
          _option(
            'TRIOMI_ACCEPTANCE_HOLD_SECONDS',
            const String.fromEnvironment('TRIOMI_ACCEPTANCE_HOLD_SECONDS'),
            '5',
          ),
        ) ??
        5;
    await Future<void>.delayed(Duration(seconds: hold.clamp(0, 60)));
  } catch (error) {
    try {
      record['nativeAcceptance'] = await const MethodChannel(
        'triomi/platform',
      ).invokeMapMethod<String, Object?>('desktopMihonAcceptanceDiagnostics');
    } catch (_) {}
    record.addAll({
      'status': 'failed',
      'errorType': error.runtimeType.toString(),
    });
    final code = error is StateError
        ? error.message
        : error is PlatformException
        ? error.code
        : null;
    if (code is String && RegExp(r'^[a-z_]+$').hasMatch(code)) {
      record['errorCode'] = code;
    }
    if (root != null) await publish('${record['stage']}');
    debugPrint('WINDOWS_MIHON_ACCEPTANCE_FAILED ${jsonEncode(record)}');
  } finally {
    runApp(const SizedBox.shrink());
    WidgetsBinding.instance.scheduleForcedFrame();
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    try {
      await const MethodChannel('triomi/platform')
          .invokeMethod<Object?>('desktopMihonStop');
    } catch (_) {}
    container?.dispose();
    await database?.close();
    await Hive.close();
  }
  exit(succeeded ? 0 : 1);
}
