import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/source/http_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

Uint8List _legacyZip() {
  final archive = Archive()
    ..add(
      ArchiveFile.string(
        'data.json',
        jsonEncode({
          'version': 1,
          'mediaItems': <Object?>[],
          'libraryEntries': <Object?>[],
          'histories': <Object?>[],
          'settingsValues': {'theme': 'incoming'},
        }),
      ),
    )
    ..add(ArchiveFile.string('safe.json', '{}'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('legacy CRC corruption is rejected before settings and SQL mutation', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final prefs = memoryPreferences();
    await prefs.set('theme', 'local');
    final bytes = _legacyZip();
    final data = ByteData.sublistView(bytes);
    // Corrupt the advertised central-directory CRC, preserving a parseable ZIP.
    for (var i = 0; i < bytes.length - 4; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(
          i + 16,
          data.getUint32(i + 16, Endian.little) ^ 1,
          Endian.little,
        );
        break;
      }
    }
    final service = BackupService(
      database: db,
      preferences: prefs,
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    );
    await expectLater(
      () => service.importFromBytes(bytes),
      throwsFormatException,
    );
    final dir = await Directory.systemTemp.createTemp('corrupt-backup-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/corrupt.zip').writeAsBytes(bytes);
    await expectLater(
      () => service.importFromFile(file.path),
      throwsFormatException,
    );
    expect(prefs.get<String>('theme'), 'local');
    expect(await db.select(db.backupImportJournals).get(), isEmpty);
  });

  test(
    'duplicate central-directory names cannot silently replace data.json',
    () async {
      final bytes = _legacyZip();
      final from = ascii.encode('safe.json'), to = ascii.encode('data.json');
      // Both local header and central header names have identical length.
      var replacements = 0;
      for (var i = 0; i <= bytes.length - from.length; i++) {
        if (List.generate(
          from.length,
          (j) => bytes[i + j],
        ).indexed.every((pair) => pair.$2 == from[pair.$1])) {
          bytes.setRange(i, i + to.length, to);
          replacements++;
        }
      }
      expect(replacements, 2);
      expect(
        () => BackupService.validatedPayload(bytes),
        throwsFormatException,
      );
      final dir = await Directory.systemTemp.createTemp('duplicate-backup-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/duplicate.zip').writeAsBytes(bytes);
      final db = openTestDatabase();
      addTearDown(db.close);
      await expectLater(
        () => BackupService(
          database: db,
          preferences: memoryPreferences(),
          http: FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: ''),
          ),
        ).importFromFile(file.path),
        throwsFormatException,
      );
    },
  );
}
