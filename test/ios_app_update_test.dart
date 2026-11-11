import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as zip;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/settings/app_update_page.dart';
import 'package:triomi/features/settings/app_update_service.dart';
import 'package:triomi/features/settings/app_update_task.dart';

import 'fixtures/fake_preferences.dart';

const _ipaName = 'Triomi-iOS-Unsigned.ipa';
const _hash =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _installed = AppUpdateInfo(
  platform: 'ios',
  packageName: 'io.github.hyperionhxh.triomi',
  version: '0.15.4',
  versionCode: 198,
  iosRevision: 1,
  sha256: _hash,
);

List<int> _ipa({String? extra, List<int>? plist}) {
  final bytes =
      plist ??
      utf8.encode('''<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.hyperionhxh.triomi</string>
<key>CFBundleShortVersionString</key><string>0.15.4</string>
<key>CFBundleVersion</key><string>198</string>
<key>CFBundleExecutable</key><string>Runner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>TriomiIosRevision</key><integer>2</integer></dict></plist>''');
  final archive = zip.Archive()
    ..addFile(
      zip.ArchiveFile('Payload/Runner.app/Info.plist', bytes.length, bytes),
    )
    ..addFile(zip.ArchiveFile('Payload/Runner.app/Runner', 3, [1, 2, 3]));
  if (extra != null) archive.addFile(zip.ArchiveFile(extra, 1, [1]));
  return zip.ZipEncoder().encode(archive);
}

Uint8List _withEocdComment(List<int> archive, Uint8List comment) {
  final result = Uint8List.fromList([...archive, ...comment]);
  ByteData.sublistView(result)
      .setUint16(archive.length - 2, comment.length, Endian.little);
  return result;
}

Uint8List _zip64Override(List<int> archive) {
  final end = archive.length - 22;
  final record = Uint8List(76);
  final metadata = ByteData.sublistView(record);
  metadata.setUint32(0, 0x06064b50, Endian.little);
  metadata.setUint64(4, 44, Endian.little);
  metadata.setUint16(12, 45, Endian.little);
  metadata.setUint16(14, 45, Endian.little);
  metadata.setUint64(24, 1 << 32, Endian.little);
  metadata.setUint64(32, 1 << 32, Endian.little);
  metadata.setUint64(40, 1 << 32, Endian.little);
  metadata.setUint32(56, 0x07064b50, Endian.little);
  metadata.setUint64(64, end, Endian.little);
  metadata.setUint32(72, 1, Endian.little);
  final result = Uint8List.fromList([
    ...archive.sublist(0, end),
    ...record,
    ...archive.sublist(end),
  ]);
  final data = ByteData.sublistView(result);
  // Keep the ordinary EOCD's checked range valid. An independent ZIP64 scan
  // could nevertheless replace these bounded fields with the huge record.
  data.setUint32(
    end + 76 + 12,
    data.getUint32(end + 76 + 12, Endian.little) + 76,
    Endian.little,
  );
  return result;
}

class _Transport implements HttpClientAdapter {
  _Transport() : revision = 2, tag = 'v0.15.4-ios.198-r2', build = 198;
  String tag;
  int revision, build;
  bool corruptPayload = false, corruptManifest = false;
  final requests = <Uri>[];
  final payload = _ipa();
  StreamController<Uint8List>? pendingPayload;
  final payloadRequested = Completer<void>();
  String get hash => sha256.convert(payload).toString();
  Map<String, Object?> get manifest => {
    'platform': 'ios',
    'packageName': _installed.packageName,
    'version': '0.15.4',
    'versionCode': build,
    'iosRevision': revision,
    'sha256': hash,
  };
  List<int> get manifestBytes => utf8.encode(jsonEncode(manifest));
  List<int> get sums => utf8.encode(
    '${sha256.convert(manifestBytes)}  triomi-ios.update.json\n$hash  $_ipaName\n',
  );
  Map<String, Object?> asset(String name, List<int> bytes) => {
    'name': name,
    'size': bytes.length,
    'state': 'uploaded',
    'digest': 'sha256:${sha256.convert(bytes)}',
    'browser_download_url':
        'https://github.com/$appUpdateRepository/releases/download/$tag/$name',
  };
  Map<String, Object?> get release => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'body': 'iOS servicing',
    'assets': [
      asset(_ipaName, payload),
      asset('triomi-ios.update.json', manifestBytes),
      asset('SHA256SUMS.txt', sums),
    ],
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    if (options.uri.toString() == appUpdateReleasesApi) {
      return ResponseBody.fromString(jsonEncode([release]), 200);
    }
    final name = options.uri.pathSegments.last;
    if (name == 'SHA256SUMS.txt') return ResponseBody.fromBytes(sums, 200);
    if (name == 'triomi-ios.update.json') {
      return ResponseBody.fromBytes(
        corruptManifest ? [1, 2] : manifestBytes,
        200,
      );
    }
    if (name == _ipaName) {
      if (!payloadRequested.isCompleted) payloadRequested.complete();
      if (pendingPayload != null) {
        unawaited(
          cancelFuture?.then((_) {
            if (!pendingPayload!.isClosed) {
              pendingPayload!.addError(const AppUpdateCancelled());
              unawaited(pendingPayload!.close());
            }
          }),
        );
        return ResponseBody(pendingPayload!.stream, 200);
      }
      return ResponseBody.fromBytes(
        corruptPayload ? List.filled(payload.length, 0) : payload,
        200,
      );
    }
    throw StateError('Unexpected updater request');
  }

  @override
  void close({bool force = false}) {}
}

class _Service extends AppUpdateService {
  _Service(this.transport) : super(dio: Dio()..httpClientAdapter = transport);
  final _Transport transport;
  @override
  Future<AppUpdateInfo> current() async => _installed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/app-update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late _Transport transport;
  late _Service service;
  final stages = <String>{};
  var handoffs = 0;
  var sharePinned = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('triomi-ios-update-test-');
    transport = _Transport();
    service = _Service(transport);
    stages.clear();
    handoffs = 0;
    sharePinned = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>();
      switch (call.method) {
        case 'beginIosStage':
          final directory = await root.createTemp('stage-');
          final path = '${directory.path}/$_ipaName';
          stages.add(path);
          return path;
        case 'inspectIos':
          // The OS boundary parses binary/XML plist on-device. Keep download,
          // integrity, archive inspection, policy and task ownership real here.
          return transport.manifest;
        case 'discardIos':
          final path = args!['path'] as String;
          if (sharePinned) return false;
          File(path).parent.deleteSync(recursive: true);
          stages.remove(path);
          return true;
        case 'handoffIos':
          handoffs++;
          sharePinned = true;
          return true;
        default:
          throw StateError(
            'An iOS consumer requested Android-only ${call.method}',
          );
      }
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    service.close();
    await root.delete(recursive: true);
  });

  test(
    'startup resolves bundled servicing revisions without downloading IPA',
    () async {
      final preferences = memoryPreferences();
      final offered = await checkStartupAppUpdate(
        preferences,
        createService: () => service,
      );
      expect(offered?.release.tag, transport.tag);
      expect(offered?.release.advertisedBuild, 198);
      expect(offered?.release.iosRevision, 2);
      expect(
        transport.requests.any((uri) => uri.path.endsWith('.ipa')),
        isFalse,
      );
      expect(stages, isEmpty);
      expect(handoffs, 0);
    },
  );

  test('same bundled revision, older build, and mismatched tag metadata never offer reinstall', () async {
    final token = AppUpdateCancellation();
    transport.revision = 1;
    transport.tag = 'v0.15.4-ios.198-r1';
    var releases = await service.resolvePlatformRevisions(
      _installed,
      await service.releases(token),
      token,
    );
    expect(newestAppUpdateRelease(_installed, releases), isNull);
    transport.build = 197;
    transport.tag = 'v0.15.4-ios.197-r1';
    releases = await service.resolvePlatformRevisions(
      _installed,
      await service.releases(token),
      token,
    );
    expect(newestAppUpdateRelease(_installed, releases), isNull);
    transport.tag = 'v0.15.4-ios.198-r2';
    await expectLater(
      service.resolvePlatformRevisions(
        _installed,
        await service.releases(token),
        token,
      ),
      throwsFormatException,
    );
    expect(transport.requests.any((uri) => uri.path.endsWith('.ipa')), isFalse);
  });

  test('original independent tag means revision zero and iOS releases never leak to Android', () async {
    transport.tag = 'v0.15.4-ios.198';
    transport.revision = 0;
    final token = AppUpdateCancellation();
    final releases = await service.releases(token);
    final ios = await service.resolvePlatformRevisions(
      _installed,
      releases,
      token,
    );
    expect(ios.single.iosRevision, 0);
    expect(newestAppUpdateRelease(_installed, ios), isNull);
    const android = AppUpdateInfo(
      platform: 'android',
      packageName: 'io.github.hyperionhxh.triomi',
      version: '0.15.3',
      versionCode: 197,
      sha256: _hash,
    );
    final requestsBefore = transport.requests.length;
    expect(
      await service.resolvePlatformRevisions(android, releases, token),
      isEmpty,
    );
    expect(transport.requests.length, requestsBefore);
  });

  test('corrupt published metadata is rejected before staging', () async {
    transport.corruptManifest = true;
    final token = AppUpdateCancellation();
    await expectLater(
      service.resolvePlatformRevisions(
        _installed,
        await service.releases(token),
        token,
      ),
      throwsFormatException,
    );
    expect(stages, isEmpty);
  });

  test(
    'real download removes corrupt IPA and task retries with clean ownership',
    () async {
      final token = AppUpdateCancellation();
      final release = (await service.releases(token)).single;
      final task = AppUpdateTask.forService(service);
      transport.corruptPayload = true;
      await task.start(release);
      expect(task.error, contains('SHA-256'));
      expect(task.candidate, isNull);
      expect(stages, isEmpty);
      transport.corruptPayload = false;
      await task.start(release);
      expect(task.error, isNull);
      expect(task.candidate?.offered.iosRevision, 2);
      expect(task.candidate?.signatureVerified, isFalse);
      expect(stages.length, 1);
      expect(handoffs, 0);
    },
  );

  test('detaching download consumers does not cancel transfer; explicit cancellation cleans and retry succeeds', () async {
    final release = (await service.releases(AppUpdateCancellation())).single;
    final task = AppUpdateTask.forService(service);
    void consumer() {}
    task.addListener(consumer);
    transport.pendingPayload = StreamController<Uint8List>();
    final running = task.start(release);
    await transport.payloadRequested.future;
    task.removeListener(consumer);
    expect(task.active, isTrue);
    expect(task.start(release), same(running));
    task.addListener(consumer);
    await task.cancel();
    await running;
    expect(task.cancelled, isTrue);
    expect(task.error, isNull);
    expect(stages, isEmpty);
    transport.pendingPayload = null;
    await task.start(release);
    expect(task.candidate?.canInstall, isTrue);
    expect(handoffs, 0);
    task.removeListener(consumer);
  });

  testWidgets(
    'iOS share cancellation retains a removable IPA across route reopening and active share refuses deletion',
    (tester) async {
      final task = AppUpdateTask.forService(service);
      await tester.runAsync(() async {
        final release = (await service.releases(AppUpdateCancellation()))
            .single;
        await task.start(release);
      });
      expect(task.error, isNull);
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AppUpdatePage(service: service),
                  ),
                ),
                child: const Text('updates'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('updates'));
      await tester.pumpAndSettle();
      expect(find.text('分享 IPA / 交给安装工具'), findsOneWidget);
      expect(find.text('选择本地 APK'), findsNothing);
      key.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('updates'));
      await tester.pumpAndSettle();
      expect(task.candidate, isNotNull);
      expect(handoffs, 0);
      await tester.tap(find.byKey(const ValueKey('app-update-ready-install')));
      await tester.pumpAndSettle();
      expect(handoffs, 0);
      expect(find.text('分享 IPA'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('app-update-ready-confirm')));
      await tester.pumpAndSettle();
      expect(handoffs, 1);
      expect(find.text('IPA 分享已打开'), findsOneWidget);
      expect(find.text('已交给系统安装器'), findsNothing);
      final discard = find.byKey(const ValueKey('app-update-handoff-discard'));
      await tester.ensureVisible(discard);
      await tester.tap(discard);
      await tester.pumpAndSettle();
      expect(task.candidate, isNotNull);
      expect(stages.length, 1);
      // Native clears the file pin when the user cancels/completes the sheet;
      // route ownership and the real service must still allow explicit cleanup.
      sharePinned = false;
      key.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('updates'));
      await tester.pumpAndSettle();
      expect(task.candidate, isNotNull);
      expect(find.text('IPA 分享已打开'), findsOneWidget);
      await tester.ensureVisible(discard);
      await tester.tap(discard);
      await tester.pumpAndSettle();
      expect(task.candidate, isNull);
      expect(task.handedOff, isFalse);
      expect(stages, isEmpty);
      expect(find.text('IPA 分享已打开'), findsNothing);
    },
  );
  test('IPA rejects EOCD-shaped comment and ZIP64 override before directory materialization', () async {
    final comment = Uint8List(22);
    final forged = ByteData.sublistView(comment);
    forged.setUint32(0, 0x06054b50, Endian.little);
    forged.setUint16(10, 65535, Endian.little);
    forged.setUint32(12, 0xffffffff, Endian.little);
    // Not a terminal EOCD: the genuine EOCD remains the unique valid one.
    // A reader merely scanning backwards for the signature would choose this.
    forged.setUint16(20, 1, Endian.little);
    final commented = await File('${root.path}/comment.ipa')
        .writeAsBytes(_withEocdComment(_ipa(), comment));
    await expectLater(
      inspectIosUpdateZip(commented.path, '${root.path}/cancel'),
      throwsA(
        isA<FormatException>().having(
          (failure) => failure.message,
          'boundary',
          contains('注释中存在替代目录'),
        ),
      ),
    );
    final zip64 = await File('${root.path}/zip64.ipa')
        .writeAsBytes(_zip64Override(_ipa()));
    await expectLater(
      inspectIosUpdateZip(zip64.path, '${root.path}/cancel'),
      throwsA(
        isA<FormatException>().having(
          (failure) => failure.message,
          'boundary',
          contains('ZIP64'),
        ),
      ),
    );
  });

  test('IPA enforces actual central entry cap during parsing despite a small EOCD count', () async {
    final archive = zip.Archive();
    for (var i = 0; i < 10001; i++) {
      archive.addFile(
        zip.ArchiveFile('Payload/Runner.app/member-$i', 0, <int>[]),
      );
    }
    final bytes = Uint8List.fromList(zip.ZipEncoder().encode(archive));
    final data = ByteData.sublistView(bytes);
    final end = bytes.length - 22;
    data.setUint16(end + 8, 2, Endian.little);
    data.setUint16(end + 10, 2, Endian.little);
    final file = await File('${root.path}/underdeclared.ipa')
        .writeAsBytes(bytes);
    await expectLater(
      inspectIosUpdateZip(file.path, '${root.path}/cancel'),
      throwsA(
        isA<FormatException>().having(
          (failure) => failure.message,
          'in-loop bound',
          contains('实际成员超过 10000'),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('IPA inspection rejects unsafe members, multiple bundles, oversized plist and cancellation', () async {
    for (final bytes in [
      _ipa(extra: '../outside'),
      _ipa(extra: 'Payload/Other.app/Runner'),
      _ipa(plist: List.filled(1024 * 1024 + 1, 65)),
    ]) {
      final file = await File('${root.path}/bad.ipa').writeAsBytes(bytes);
      await expectLater(
        inspectIosUpdateZip(file.path, '${root.path}/cancel'),
        throwsFormatException,
      );
    }
    final file = await File('${root.path}/good.ipa').writeAsBytes(_ipa());
    final plist = await inspectIosUpdateZip(file.path, '${root.path}/cancel');
    expect(utf8.decode(plist), contains('TriomiIosRevision'));
    await File('${root.path}/cancel').writeAsString('cancel');
    await expectLater(
      inspectIosUpdateZip(file.path, '${root.path}/cancel'),
      throwsA(isA<AppUpdateCancelled>()),
    );
  });
}
