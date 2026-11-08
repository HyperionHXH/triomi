import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:triomi/features/novel/export/novel_export_service.dart';

void main() {
  late Directory selected;

  setUp(() async {
    selected = await Directory.systemTemp.createTemp('triomi-selected-export-');
  });
  tearDown(() async {
    await selected.delete(recursive: true);
  });

  test('selected folder receives real file and duplicate export preserves original', () async {
    final original = File(p.join(selected.path, '小说.epub'));
    await original.writeAsBytes([1, 2, 3]);
    final path = await NovelExportService.writeToLocalDirectory(
      selected.path,
      '小说.epub',
      [4, 5, 6],
    );
    expect(path, p.join(selected.path, '小说(1).epub'));
    expect(await File(path).readAsBytes(), [4, 5, 6]);
    expect(await original.readAsBytes(), [1, 2, 3]);
  });

  test(
    'export writer cannot escape selected folder through filename',
    () async {
      for (final name in [
        '../escape.txt',
        r'..\escape.txt',
        'C:escape.txt',
        '.',
        '..',
        'bad.txt.',
      ]) {
        await expectLater(
          NovelExportService.writeToLocalDirectory(selected.path, name, [1]),
          throwsArgumentError,
        );
      }
      expect(await selected.list().toList(), isEmpty);
    },
  );

  test(
    'missing selected folder fails instead of reporting a synthetic path',
    () async {
      await expectLater(
        NovelExportService.writeToLocalDirectory(
          p.join(selected.path, 'missing'),
          'book.txt',
          [1],
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
