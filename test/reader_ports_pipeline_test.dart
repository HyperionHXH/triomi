import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/widgets/image_viewer.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/portable_rule_test_support.dart';
import 'fixtures/reader_port_harness.dart';

Future<List<int>> _pixels(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final frame = await codec.getNextFrame();
  try {
    final data = (await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final id in readerPortIds) {
    sourceRuleTest(
      'Reader port production download save and offline round trip: $id',
      () async {
        final harness = await ReaderPortHarness.create();
        addTearDown(harness.close);
        final temp = await Directory.systemTemp.createTemp(
          'triomi-port-download-',
        );
        // This mock targets only this test-owned directory, never user documents.
        if (!Platform.isIOS) {
          const channel = MethodChannel('plugins.flutter.io/path_provider');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                channel,
                (call) async =>
                    call.method == 'getApplicationDocumentsDirectory'
                    ? temp.path
                    : null,
              );
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
        }
        addTearDown(() async {
          // systemTemp.createTemp provides an explicit test-owned absolute path.
          if (temp.existsSync()) await temp.delete(recursive: true);
        });
        final source = await harness.source(id);
        if (source is AccountProvider) {
          await (source as AccountProvider).login('fixture', 'fixture');
        }
        final item = await source.detail(harness.item(id));
        final chapters = await source.chapters(item);
        expect(chapters, hasLength(1));
        final content = await source.content(chapters.single);
        expect(content.images, hasLength(2));
        final saved = await loadImageBytes(
          content.images.first,
          sourceId: id,
          headers: content.imageHeaders,
          http: harness.http,
        );
        expect(
          await _pixels(saved!),
          await _pixels(harness.adapter.png),
          reason: '$id must restore the original geometry, not merely decode',
        );
        final library = LibraryRepository(harness.database);
        await library.cacheItem(item);
        await library.saveChapters(
          itemSourceId: id,
          itemRemoteId: item.remoteId,
          chapters: chapters,
        );
        final repository = DownloadRepository(harness.database);
        final rowId = await repository.enqueue(
          sourceId: id,
          remoteId: item.remoteId,
          chapter: chapters.single,
        );
        final row = (await repository.listForItem(id, item.remoteId)).single;
        expect(row.id, rowId);
        await DownloadService(
          repository: repository,
          http: harness.http,
          preferences: harness.container.read(preferencesProvider),
        ).run(row: row, provider: source);
        expect(
          (await repository.listForItem(id, item.remoteId)).single.status,
          'done',
        );
        final directory = await repository.localImageDir(
          id,
          chapters.single.remoteId,
        );
        expect(directory, isNotNull);
        final files =
            Directory(directory!)
                .listSync()
                .whereType<File>()
                .where((f) => RegExp(r'000[12]\.(png|jpg)$').hasMatch(f.path))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        expect(files, hasLength(2));
        harness.adapter.offline = true;
        final bytes = await files.first.readAsBytes();
        expect(bytes, saved);
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        final frame = await codec.getNextFrame();
        expect((frame.image.width, frame.image.height), (300, 420));
        frame.image.dispose();
        codec.dispose();
        // Remove only rows/files created in this isolated test DB, never user data.
        await DownloadService.removeFiles(
          await repository.listForItem(id, item.remoteId),
        );
      },
    );
  }
}
