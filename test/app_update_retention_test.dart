import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/settings/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/app-update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const signer =
      '2222222222222222222222222222222222222222222222222222222222222222';

  group('normal owned Android stream staging', () {
    late Directory root;
    late AppUpdateService service;
    late Set<String> active;
    late Set<String> candidates;
    late int sequence;
    late bool cancelAfterInspect;
    late bool mismatchedDecision;
    late AppUpdateCancellation token;

    Map<String, Object> info(int code, String hash) => {
      'packageName': 'io.github.hyperionhxh.triomi',
      'versionCode': code,
      'version': '0.1.$code',
      'sha256': hash,
      'signerSha256': signer,
      'platform': 'android',
    };

    setUp(() async {
      root = await Directory.systemTemp.createTemp('triomi-owned-updates-');
      await Directory('${root.path}/incoming').create();
      await Directory('${root.path}/install').create();
      active = {};
      candidates = {};
      sequence = 0;
      cancelAfterInspect = false;
      mismatchedDecision = false;
      token = AppUpdateCancellation();
      service = AppUpdateService();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, Object?>();
        switch (call.method) {
          case 'beginIncoming':
            final file = File(
              '${root.path}/incoming/download-${++sequence}.apk',
            );
            await file.create();
            active.add(file.path);
            return {'path': file.path};
          case 'inspect':
            final source = File(args!['path'] as String);
            expect(active, contains(source.path));
            final bytes = await source.readAsBytes();
            final candidate = await source.copy(
              '${root.path}/install/$sequence.apk',
            );
            await source.delete();
            active.remove(source.path);
            candidates.add(candidate.path);
            if (cancelAfterInspect) token.cancel();
            final hash = sha256.convert(bytes).toString();
            return {
              ...info(174, hash),
              'current': info(173, '1' * 64),
              'path': candidate.path,
              'bytes': bytes.length,
              'source': args['source'],
              'signatureVerified': true,
              'decision': mismatchedDecision ? 'alreadyInstalled' : 'upgrade',
            };
          case 'finishIncoming':
            final path = args!['path'] as String;
            active.remove(path);
            final file = File(path);
            if (await file.exists()) await file.delete();
            return {'removed': true};
          case 'discard':
            final path = args!['path'] as String;
            candidates.remove(path);
            final file = File(path);
            if (await file.exists()) await file.delete();
            return {'removed': true};
          default:
            throw StateError('Unexpected updater operation ${call.method}');
        }
      });
    });
    tearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      service.close();
      await root.delete(recursive: true);
    });

    Future<AppUpdateCandidate> stage(
      Stream<List<int>> stream, {
      String? hash,
    }) => service.stageAndroidApk(
      stream,
      token,
      expectedHash: hash ?? sha256.convert([1, 2, 3]).toString(),
      expectedBytes: 3,
      source: 'official regression payload',
    );

    test('two complete staging cycles leave one install copy and no incoming duplicate', () async {
      for (var update = 0; update < 2; update++) {
        token = AppUpdateCancellation();
        final candidate = await stage(Stream.value([1, 2, 3]));
        expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
        expect(await Directory('${root.path}/install').list().length, 1);
        expect(active, isEmpty);
        expect(await File(candidate.path).readAsBytes(), [1, 2, 3]);
        await service.discard(candidate);
        expect(await Directory('${root.path}/install').list().isEmpty, isTrue);
      }
    });

    test(
      'already cancelled stream is closed without allocating any owned file',
      () async {
        token.cancel();
        final source = StreamController<List<int>>();
        var cancellations = 0;
        source.onCancel = () {
          cancellations++;
        };
        await expectLater(
          stage(source.stream),
          throwsA(isA<AppUpdateCancelled>()),
        );
        expect(cancellations, 1);
        expect(sequence, 0);
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        await source.close();
      },
    );

    test(
      'failed incoming allocation closes the response and keeps its error',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'beginIncoming');
          throw PlatformException(code: 'allocation_failed');
        });
        final source = StreamController<List<int>>();
        var cancellations = 0;
        source.onCancel = () {
          cancellations++;
        };
        await expectLater(
          stage(source.stream),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'allocation_failed',
            ),
          ),
        );
        expect(cancellations, 1);
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
        await source.close();
      },
    );

    test(
      'copy setup failure closes the response and releases its incoming lease',
      () async {
        final source = StreamController<List<int>>();
        var cancellations = 0;
        source.onCancel = () {
          cancellations++;
        };
        await expectLater(
          stage(source.stream, hash: 'invalid'),
          throwsFormatException,
        );
        expect(cancellations, 1);
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
        await source.close();
      },
    );

    test('early response error reaches the caller after copy setup', () async {
      final failure = StateError('response failed');
      final source = StreamController<List<int>>();
      var cancellations = 0;
      source.onCancel = () {
        cancellations++;
      };
      source.addError(failure);
      await expectLater(stage(source.stream), throwsA(same(failure)));
      expect(cancellations, 1);
      expect(active, isEmpty);
      expect(candidates, isEmpty);
      expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
      await source.close();
    });

    test('listen setup failure does not allocate an incoming lease', () async {
      final failure = StateError('listen failed');
      final source = _ThrowingListenStream(failure);
      await expectLater(stage(source), throwsA(same(failure)));
      expect(source.listens, 1);
      expect(sequence, 0);
      expect(active, isEmpty);
      expect(candidates, isEmpty);
    });

    test(
      'cancellation while subscribing still closes the response once',
      () async {
        final source = StreamController<List<int>>(onListen: token.cancel);
        var cancellations = 0;
        source.onCancel = () {
          cancellations++;
        };
        await expectLater(
          stage(source.stream),
          throwsA(isA<AppUpdateCancelled>()),
        );
        expect(cancellations, 1);
        expect(sequence, 0);
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        await source.close();
      },
    );

    test('source cancellation errors remain visible to the caller', () async {
      token.cancel();
      final failure = StateError('response close failed');
      final source = StreamController<List<int>>();
      var cancellations = 0;
      source.onCancel = () {
        cancellations++;
        return Future<void>.error(failure);
      };
      await expectLater(stage(source.stream), throwsA(same(failure)));
      expect(cancellations, 1);
      expect(sequence, 0);
      expect(active, isEmpty);
      expect(candidates, isEmpty);
      await source.close();
    });

    test('response cancellation waits for asynchronous cleanup', () async {
      token.cancel();
      final closing = Completer<void>();
      final release = Completer<void>();
      final source = StreamController<List<int>>();
      var cancellations = 0;
      source.onCancel = () {
        cancellations++;
        closing.complete();
        return release.future;
      };
      var settled = false;
      final staged = stage(source.stream);
      final rejected = expectLater(staged, throwsA(isA<AppUpdateCancelled>()))
          .then((_) {
            settled = true;
          });
      await closing.future;
      expect(settled, isFalse);
      expect(cancellations, 1);
      expect(sequence, 0);
      release.complete();
      await rejected;
      expect(settled, isTrue);
      expect(active, isEmpty);
      expect(candidates, isEmpty);
      await source.close();
    });

    test('cancelling a stalled source closes it and removes partial incoming bytes', () async {
      final source = StreamController<List<int>>();
      final receiving = Completer<void>();
      var closed = false;
      source.onCancel = () {
        closed = true;
      };
      service.onProgress = (_) {
        if (!receiving.isCompleted) receiving.complete();
      };
      final staged = stage(source.stream);
      final rejected = expectLater(staged, throwsA(isA<AppUpdateCancelled>()));
      source.add([1]);
      await receiving.future;
      token.cancel();
      await rejected;
      expect(closed, isTrue);
      expect(active, isEmpty);
      expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
      await source.close();
    });

    test('current active download keeps its lease through multiple streamed chunks', () async {
      final stream = StreamController<List<int>>();
      final receiving = Completer<void>();
      service.onProgress = (_) {
        if (!receiving.isCompleted) receiving.complete();
      };
      final staged = stage(stream.stream);
      stream.add([1]);
      await receiving.future;
      expect(active, hasLength(1));
      expect(await File(active.single).readAsBytes(), [1]);
      stream.add([2, 3]);
      await stream.close();
      final candidate = await staged;
      expect(active, isEmpty);
      await service.discard(candidate);
    });

    test(
      'cancel after native candidate publication releases both owned files',
      () async {
        cancelAfterInspect = true;
        await expectLater(
          stage(Stream.value([1, 2, 3])),
          throwsA(isA<AppUpdateCancelled>()),
        );
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
        expect(await Directory('${root.path}/install').list().isEmpty, isTrue);
      },
    );

    test(
      'native policy mismatch never strands an otherwise unpublished candidate',
      () async {
        mismatchedDecision = true;
        await expectLater(
          stage(Stream.value([1, 2, 3])),
          throwsFormatException,
        );
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        expect(await Directory('${root.path}/install').list().isEmpty, isTrue);
      },
    );

    test(
      'truncation and digest failure release the native incoming lease',
      () async {
        await expectLater(stage(Stream.value([1])), throwsFormatException);
        token = AppUpdateCancellation();
        await expectLater(
          stage(Stream.value([1, 2, 3]), hash: '3' * 64),
          throwsFormatException,
        );
        expect(active, isEmpty);
        expect(candidates, isEmpty);
        expect(await Directory('${root.path}/incoming').list().isEmpty, isTrue);
      },
    );
  });

  test('stream staging rejects symbolic-link and directory destinations without touching contents', () async {
    final root = await Directory.systemTemp.createTemp('triomi-link-update-');
    try {
      final target = File('${root.path}/user.apk');
      await target.writeAsString('preserve');
      final link = Link('${root.path}/stage.apk');
      await link.create(target.path);
      await expectLater(
        stageAppUpdateBytes(
          Stream.value([1]),
          File(link.path),
          cancellation: AppUpdateCancellation(),
        ),
        throwsA(isA<FileSystemException>()),
      );
      final directory = await Directory('${root.path}/directory.apk').create();
      await expectLater(
        stageAppUpdateBytes(
          Stream.value([1]),
          File(directory.path),
          cancellation: AppUpdateCancellation(),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), 'preserve');
      expect(await link.exists(), isTrue);
      expect(await directory.exists(), isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: Platform.isWindows);

  test('storage breakdown includes both roots and excludes protected bytes from clear eligibility', () {
    final info = AppUpdateStorageInfo.fromMap({
      'incomingBytes': 2,
      'installBytes': 5,
      'legacyBytes': 11,
      'reclaimableBytes': 7,
      'protectedBytes': 11,
      'removedBytes': 13,
      'skippedFiles': 1,
    });
    expect(info.totalBytes, 18);
    expect(info.reclaimableBytes, 7);
    expect(info.protectedBytes, 11);
    expect(info.removedBytes, 13);
  });
}

class _ThrowingListenStream extends Stream<List<int>> {
  _ThrowingListenStream(this.failure);

  final Object failure;
  int listens = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listens++;
    throw failure;
  }
}
