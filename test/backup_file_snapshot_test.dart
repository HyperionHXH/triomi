import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibEncoder;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/verified_backup_file.dart';
import 'package:triomi/core/backup/versioned_webdav_backup.dart';
import 'package:triomi/core/source/http_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('backup-snapshot-test-');
    IOOverrides.global = _BackupTemporaryDirectory(temporary);
  });
  tearDown(() async {
    IOOverrides.global = null;
    await temporary.delete(recursive: true);
  });
  test(
    'reviewed disk snapshot rejects replaced ZIP before any local mutation',
    () async {
      final dir = await Directory.systemTemp.createTemp('restore-review-');
      addTearDown(() => dir.delete(recursive: true));
      final db = openTestDatabase();
      addTearDown(db.close);
      final prefs = memoryPreferences();
      await prefs.set('theme', 'local');
      final service = BackupService(
        database: db,
        preferences: prefs,
        http: FakeHttpClient(
          (_) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );
      final path = '${dir.path}/backup.zip';
      Future<void> write(String theme) async {
        final archive = Archive()
          ..addFile(
            ArchiveFile.string(
              'data.json',
              jsonEncode({
                'version': 1,
                'libraryEntries': <Object?>[],
                'settingsValues': {'theme': theme},
              }),
            ),
          );
        await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive));
      }

      await write('reviewed');
      final preview = await previewBackupRestoreFile(db, path);
      await write('replacement');
      await expectLater(
        () => service.importFromFile(path, expectedHash: preview.byteHash),
        throwsFormatException,
      );
      expect(prefs.get<String>('theme'), 'local');
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
      final freshPreview = await previewBackupRestoreFile(db, path);
      await service.importFromFile(path, expectedHash: freshPreview.byteHash);
      expect(prefs.get<String>('theme'), 'replacement');
    },
  );

  test('disk verification streams entries, validates manifest, and uses generated paths', () async {
    final dir = await Directory.systemTemp.createTemp('restore-disk-');
    addTearDown(() => dir.delete(recursive: true));
    final payload = utf8.encode(jsonEncode({'version': 1}));
    final body = List<int>.generate(4 * 1024 * 1024, (i) => i % 251);
    final member = 'media/${'a' * 64}/video.mp4';
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('data.json', payload))
      ..addFile(ArchiveFile.bytes(member, body))
      ..addFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'version': 1,
            'files': {
              'data.json': {
                'size': payload.length,
                'sha256': sha256.convert(payload).toString(),
              },
              member: {
                'size': body.length,
                'sha256': sha256.convert(body).toString(),
              },
            },
          }),
        ),
      );
    final zip = File('${dir.path}/input.zip');
    final output = OutputFileStream(zip.path);
    ZipEncoder().encodeStream(archive, output);
    await output.close();
    final snapshot = await VerifiedBackupFile.open(zip.path);
    final tempPath = snapshot.directory.path;
    try {
      final file = snapshot.files[member]!;
      expect(file.parent.path, tempPath);
      expect(
        (await sha256.bind(file.openRead()).first).toString(),
        sha256.convert(body).toString(),
      );
      expect(snapshot.payload, {'version': 1});
    } finally {
      await snapshot.close();
    }
    expect(Directory(tempPath).existsSync(), isFalse);
  });


  test('preview retains CRC and manifest SHA verification for supported members', () async {
    final dir = await Directory.systemTemp.createTemp('restore-integrity-');
    addTearDown(() => dir.delete(recursive: true));
    final db = openTestDatabase();
    addTearDown(db.close);
    final payload = utf8.encode('{"version":1}');
    for (final corruptCrc in [true, false]) {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('data.json', payload))
        ..addFile(ArchiveFile.string('manifest.json', jsonEncode({
          'version': 1, 'files': {'data.json': {
            'size': payload.length,
            'sha256': corruptCrc ? sha256.convert(payload).toString() : '0' * 64,
          }},
        })));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      if (corruptCrc) {
        final data = ByteData.sublistView(bytes);
        final central = data.getUint32(bytes.length - 22 + 16, Endian.little);
        data.setUint32(central + 16, data.getUint32(central + 16, Endian.little) ^ 1, Endian.little);
      }
      final file = await File('${dir.path}/corrupt-$corruptCrc.zip').writeAsBytes(bytes);
      final before = await _restoreDirectories();
      await expectLater(previewBackupRestoreFile(db, file.path), throwsFormatException);
      expect(await _restoreDirectories(), before);
    }
  });
  test('preview rejects forged-small deflate and stored output without mutation or staging', () async {
    final dir = await Directory.systemTemp.createTemp('restore-quota-');
    addTearDown(() => dir.delete(recursive: true));
    final db = openTestDatabase();
    addTearDown(db.close);
    final prefs = memoryPreferences();
    await prefs.set('theme', 'local');
    final service = BackupService(database: db, preferences: prefs,
      http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')));
    final before = await _restoreDirectories();
    for (final compressed in [true, false]) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('data.json', jsonEncode({
          'version': 1, 'settingsValues': {'theme': 'incoming'},
        })))
        ..addFile(ArchiveFile.bytes('media/${'a' * 64}/video.mp4', Uint8List(8 * 1024 * 1024))
          ..compression = compressed ? CompressionType.deflate : CompressionType.none);
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      _declareSize(bytes, 'media/${'a' * 64}/video.mp4', 1);
      final file = await File('${dir.path}/forged-$compressed.zip').writeAsBytes(bytes);
      await expectLater(previewBackupRestoreFile(db, file.path),
        throwsA(isA<FormatException>().having((error) => error.message, 'quota rejection',
          contains(compressed ? '实际解压内容超过声明' : '声明大小超限'))));
      await expectLater(service.importFromFile(file.path), throwsFormatException);
      expect(await _restoreDirectories(), before);
      expect(prefs.get<String>('theme'), 'local');
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
      expect(await db.select(db.libraryEntries).get(), isEmpty);
      if (Platform.isWindows || Platform.isAndroid) {
        final cleanup = await BackupArtifactGuard.acquireCleanup();
        expect(cleanup, isNotNull, reason: 'rejection must release the snapshot operation lease');
        await cleanup?.release();
      }
    }
  });

  test('preview rejects enormous unreferenced and unknown members before extraction', () async {
    final dir = await Directory.systemTemp.createTemp('restore-extra-');
    addTearDown(() => dir.delete(recursive: true));
    final db = openTestDatabase();
    addTearDown(db.close);
    final before = await _restoreDirectories();
    for (final member in ['unused.bin', '../../outside.bin', 'media/${'a' * 64}/video.mp4']) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('data.json', '{"version":1}'))
        ..addFile(ArchiveFile.bytes(member, [1]));
      final encoded = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      final bytes = _declareZip64Size(encoded, member, VersionedWebDavBackup.maxFileSize + 1);
      final file = await File('${dir.path}/extra.zip').writeAsBytes(bytes);
      await expectLater(previewBackupRestoreFile(db, file.path), throwsFormatException);
      expect(await _restoreDirectories(), before);
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
    }
  });

  test('JSON, manifest, central directory and count declarations are bounded before decode', () async {
    final dir = await Directory.systemTemp.createTemp('restore-preflight-');
    addTearDown(() => dir.delete(recursive: true));
    final before = await _restoreDirectories();
    for (final member in ['data.json', 'manifest.json', 'covers/old-name.jpg', 'media/${'a' * 64}/manifest.json']) {
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
        ..addFile(ArchiveFile.string('data.json', '{"version":1}'))
        ..addFile(ArchiveFile.string(member == 'data.json' ? 'manifest.json' : member, '{}'))));
      _declareSize(bytes, member, 256 * 1024 * 1024 + 1);
      final file = await File('${dir.path}/metadata.zip').writeAsBytes(bytes);
      await expectLater(VerifiedBackupFile.open(file.path), throwsFormatException);
      expect(await _restoreDirectories(), before);
    }
    final valid = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
      ..addFile(ArchiveFile.string('data.json', '{"version":1}'))));
    for (final directoryBytes in [false, true]) {
      final bytes = Uint8List.fromList(valid);
      final data = ByteData.sublistView(bytes);
      final end = bytes.length - 22;
      if (directoryBytes) {
        data.setUint32(end + 12, 32 * 1024 * 1024 + 1, Endian.little);
      } else {
        data.setUint16(end + 8, 60000, Endian.little);
        data.setUint16(end + 10, 60000, Endian.little);
      }
      final file = await File('${dir.path}/directory.zip').writeAsBytes(bytes);
      await expectLater(VerifiedBackupFile.open(file.path), throwsFormatException);
      expect(await _restoreDirectories(), before);
    }
  });

  test('cumulative declarations reject many individually supported media entries', () async {
    final dir = await Directory.systemTemp.createTemp('restore-total-');
    addTearDown(() => dir.delete(recursive: true));
    final members = [for (var i = 0; i < 5; i++) 'media/${'$i' * 64}/video.mp4'];
    final archive = Archive()..addFile(ArchiveFile.string('data.json', '{"version":1}'));
    for (final member in members) { archive.addFile(ArchiveFile.bytes(member, [1])); }
    final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
    for (final member in members) { _declareSize(bytes, member, 0xfffffffe); }
    final file = await File('${dir.path}/total.zip').writeAsBytes(bytes);
    final before = await _restoreDirectories();
    await expectLater(VerifiedBackupFile.open(file.path),
      throwsA(isA<FormatException>().having((error) => error.message, 'preflight quota', contains('声明大小超限'))));
    expect(await _restoreDirectories(), before);
  });

  test('oversized snapshot is rejected before copying the sparse source', () async {
    final dir = await Directory.systemTemp.createTemp('restore-sparse-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/oversized.zip');
    final output = await file.open(mode: FileMode.writeOnly);
    if (Platform.isWindows) {
      final result = await Process.run('fsutil', ['sparse', 'setflag', file.path]);
      if (result.exitCode != 0) {
        await output.close();
        throw StateError('Cannot create sparse boundary fixture: ${result.stderr}');
      }
    }
    await output.setPosition(VersionedWebDavBackup.maxFileSize);
    await output.writeByte(0);
    await output.close();
    final before = await _restoreDirectories();
    await expectLater(VerifiedBackupFile.open(file.path), throwsFormatException);
    expect(await _restoreDirectories(), before);
  });

  test('legacy covers and ZIP64 metadata remain valid', () async {
    final dir = await Directory.systemTemp.createTemp('restore-legacy-');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
      ..addFile(ArchiveFile.string('data.json', '{"version":1}'))
      ..addFile(ArchiveFile.bytes('covers/old-source-item.jpg', [1, 2, 3]))));
    final file = await File('${dir.path}/legacy.zip').writeAsBytes(_zip64Directory(bytes));
    final snapshot = await VerifiedBackupFile.open(file.path);
    try {
      expect(snapshot.payload, {'version': 1});
      expect(await snapshot.files['covers/old-source-item.jpg']!.readAsBytes(), [1, 2, 3]);
    } finally {
      await snapshot.close();
    }
  });

  test('503MiB compressed media is streamed without the 256MiB JSON/byte API cap', () async {
    final dir = await Directory.systemTemp.createTemp('restore-large-');
    addTearDown(() => dir.delete(recursive: true));
    const size = 503 * 1024 * 1024;
    final block = Uint8List(1024 * 1024);
    var crc = 0;
    Stream<List<int>> body() async* {
      for (var i = 0; i < 503; i++) {
        crc = getCrc32(block, crc);
        yield block;
      }
    }
    final compressed = File('${dir.path}/body.deflate');
    await ZLibEncoder(raw: true).bind(body()).pipe(compressed.openWrite());
    final file = await _mediaZip(dir, compressed, size, crc);
    final db = openTestDatabase();
    final before = await _restoreDirectories();
    addTearDown(db.close);
    final preview = await previewBackupRestoreFile(db, file.path);
    expect(preview.downloadedMedia, 1);
    expect(await _restoreDirectories(), before);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<Set<String>> _restoreDirectories() async => {
  await for (final entry in Directory.systemTemp.list(followLinks: false))
    if (entry is Directory && entry.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('triomi-restore-'))
      entry.path,
};

void _declareSize(Uint8List bytes, String member, int size) {
  final data = ByteData.sublistView(bytes);
  var changed = 0;
  for (var i = 0; i + 30 <= bytes.length; i++) {
    final signature = data.getUint32(i, Endian.little);
    final central = signature == 0x02014b50;
    if (!central && signature != 0x04034b50) continue;
    if (central && i + 46 > bytes.length) continue;
    final nameLength = data.getUint16(i + (central ? 28 : 26), Endian.little);
    final nameOffset = i + (central ? 46 : 30);
    if (nameOffset + nameLength <= bytes.length && utf8.decode(bytes.sublist(nameOffset, nameOffset + nameLength)) == member) {
      data.setUint32(i + (central ? 24 : 22), size, Endian.little);
      changed++;
    }
  }
  expect(changed, 2);
}

Uint8List _declareZip64Size(Uint8List original, String member, int size) {
  _declareSize(original, member, 0xffffffff);
  final old = ByteData.sublistView(original);
  var position = old.getUint32(original.length - 22 + 16, Endian.little);
  while (position < original.length - 22) {
    final nameSize = old.getUint16(position + 28, Endian.little);
    final extraSize = old.getUint16(position + 30, Endian.little);
    final commentSize = old.getUint16(position + 32, Endian.little);
    final name = utf8.decode(original.sublist(position + 46, position + 46 + nameSize));
    if (name == member) {
      final insertion = position + 46 + nameSize + extraSize;
      final result = Uint8List(original.length + 12)
        ..setRange(0, insertion, original)
        ..setRange(insertion + 12, original.length + 12, original, insertion);
      final data = ByteData.sublistView(result);
      data.setUint16(insertion, 1, Endian.little);
      data.setUint16(insertion + 2, 8, Endian.little);
      data.setUint64(insertion + 4, size, Endian.little);
      data.setUint16(position + 30, extraSize + 12, Endian.little);
      data.setUint32(result.length - 22 + 12, old.getUint32(original.length - 22 + 12, Endian.little) + 12, Endian.little);
      return result;
    }
    position += 46 + nameSize + extraSize + commentSize;
  }
  throw StateError('fixture member missing');
}

Uint8List _zip64Directory(Uint8List original) {
  final end = original.length - 22;
  final old = ByteData.sublistView(original);
  final extra = ByteData(76);
  extra.setUint32(0, 0x06064b50, Endian.little);
  extra.setUint64(4, 44, Endian.little);
  extra.setUint16(12, 45, Endian.little);
  extra.setUint16(14, 45, Endian.little);
  extra.setUint64(24, old.getUint16(end + 8, Endian.little), Endian.little);
  extra.setUint64(32, old.getUint16(end + 10, Endian.little), Endian.little);
  extra.setUint64(40, old.getUint32(end + 12, Endian.little), Endian.little);
  extra.setUint64(48, old.getUint32(end + 16, Endian.little), Endian.little);
  extra.setUint32(56, 0x07064b50, Endian.little);
  extra.setUint64(64, end, Endian.little);
  extra.setUint32(72, 1, Endian.little);
  final result = Uint8List(original.length + 76)
    ..setRange(0, end, original)
    ..setRange(end, end + 76, extra.buffer.asUint8List())
    ..setRange(end + 76, original.length + 76, original, end);
  final data = ByteData.sublistView(result);
  for (final offset in [6, 8, 10]) { data.setUint16(end + 76 + offset, 0xffff, Endian.little); }
  for (final offset in [12, 16]) { data.setUint32(end + 76 + offset, 0xffffffff, Endian.little); }
  return result;
}

Future<File> _mediaZip(Directory directory, File compressed, int size, int crc) async {
  final archive = Archive()
    ..addFile(ArchiveFile.string('data.json', '{"version":1,"downloadedMedia":1}'))
    ..addFile(ArchiveFile.bytes('media/${'a' * 64}/video.mp4', [0]));
  final original = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  final old = ByteData.sublistView(original);
  final end = original.length - 22;
  final central = old.getUint32(end + 16, Endian.little);
  final firstLength = 46 + old.getUint16(central + 28, Endian.little) +
    old.getUint16(central + 30, Endian.little) + old.getUint16(central + 32, Endian.little);
  final member = central + firstLength;
  final local = old.getUint32(member + 42, Endian.little);
  final start = local + 30 + old.getUint16(local + 26, Endian.little) + old.getUint16(local + 28, Endian.little);
  final compressedSize = await compressed.length();
  final prefix = Uint8List.sublistView(original, 0, start);
  final prefixData = ByteData.sublistView(prefix);
  prefixData.setUint32(local + 14, crc, Endian.little);
  prefixData.setUint32(local + 18, compressedSize, Endian.little);
  prefixData.setUint32(local + 22, size, Endian.little);
  final suffix = Uint8List.fromList(original.sublist(central));
  final suffixData = ByteData.sublistView(suffix);
  suffixData.setUint32(firstLength + 16, crc, Endian.little);
  suffixData.setUint32(firstLength + 20, compressedSize, Endian.little);
  suffixData.setUint32(firstLength + 24, size, Endian.little);
  suffixData.setUint32(suffix.length - 22 + 16, start + compressedSize, Endian.little);
  final result = File('${directory.path}/media.zip');
  final output = result.openWrite();
  output.add(prefix);
  await output.addStream(compressed.openRead());
  output.add(suffix);
  await output.close();
  return result;
}

final class _BackupTemporaryDirectory extends IOOverrides {
  _BackupTemporaryDirectory(this.directory);
  final Directory directory;
  @override
  Directory getSystemTempDirectory() => directory;
}
