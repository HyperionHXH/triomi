import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibEncoder;
import 'package:crypto/crypto.dart';

import '../source/http_client.dart';
import 'backup_progress.dart';

/// Copy a private snapshot with backpressure and cancellation between disk reads.
Future<void> copyBackupFile(
  File source,
  File destination, {
  void Function(int bytes)? onBytes,
}) async {
  checkBackupCancellation();
  final output = destination.openWrite();
  try {
    await for (final chunk in source.openRead()) {
      checkBackupCancellation();
      output.add(chunk);
      await output.flush();
      onBytes?.call(chunk.length);
    }
    checkBackupCancellation();
  } finally {
    await output.close();
  }
}

Future<String> hashBackupFile(File file) async {
  final digest = _HashSink();
  final input = sha256.startChunkedConversion(digest);
  await for (final chunk in file.openRead()) {
    checkBackupCancellation();
    input.add(chunk);
  }
  input.close();
  return digest.value!.toString();
}

/// Hash bounded slices so checking a large transfer cannot freeze the UI.
Future<String> hashBackupBytes(
  List<int> bytes, {
  Sink<List<int>>? overall,
}) async {
  final digest = _HashSink();
  final hash = sha256.startChunkedConversion(digest);
  const slice = 256 * 1024;
  for (var offset = 0; offset < bytes.length; offset += slice) {
    checkBackupCancellation();
    final end = (offset + slice).clamp(0, bytes.length);
    final part = bytes is Uint8List
        ? Uint8List.sublistView(bytes, offset, end)
        : bytes.sublist(offset, end);
    hash.add(part);
    overall?.add(part);
    if (end < bytes.length) await Future<void>.delayed(Duration.zero);
  }
  hash.close();
  return digest.value!.toString();
}

/// Only plain payload records and snapshot paths cross this boundary. SQLite,
/// HTTP clients and platform channels remain on their owning isolate.
Future<void> packBackupFile({
  required Map<String, Object?> payload,
  required Map<String, String> files,
  required String stagingPath,
  required String outputPath,
  BackupProgressCallback? onProgress,
}) async {
  checkBackupCancellation();
  final messages = ReceivePort();
  final done = Completer<void>();
  final exited = Completer<void>();
  var spawned = false;
  final flag = File('$stagingPath/cancelled');
  var active = true;
  final cancellation = SourceRequestCancellation.current;
  if (cancellation != null) {
    unawaited(
      cancellation.token.whenCancel.then((_) {
        if (active) flag.writeAsStringSync('cancel');
      }),
    );
  }
  final subscription = messages.listen((message) {
    if (message == null) {
      if (!exited.isCompleted) exited.complete();
      if (!done.isCompleted) done.completeError(StateError('备份打包进程意外停止'));
    } else if (message is BackupProgress) {
      onProgress?.call(message);
    } else if (message == true) {
      if (!done.isCompleted) done.complete();
    } else if (!done.isCompleted) {
      done.completeError(switch (message) {
        'cancelled' => const BackupCancelledException(),
        'storage' => const FileSystemException('备份暂存文件读写失败'),
        'format' => const FormatException('备份数据编码或压缩失败'),
        _ => StateError('备份文件打包失败；未上传或发布'),
      });
    }
  });
  try {
    await Isolate.spawn(
      _packWorker,
      (messages.sendPort, payload, files, stagingPath, outputPath),
      onError: messages.sendPort,
      onExit: messages.sendPort,
      errorsAreFatal: true,
    );
    spawned = true;
    // Never time out and detach this worker: it must close files before cleanup.
    await done.future;
    checkBackupCancellation();
  } finally {
    if (spawned) await exited.future;
    active = false;
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _packWorker(
  (SendPort, Map<String, Object?>, Map<String, String>, String, String) job,
) async {
  final (port, payload, paths, staging, outputPath) = job;
  final cancel = File('$staging/cancelled');
  void check() {
    if (cancel.existsSync()) throw const BackupCancelledException();
  }

  Object result = true;
  final prepared = <(String, String, int, int, bool)>[];
  ArchiveFile? member;
  OutputFileStream? output;
  try {
    check();
    port.send(const BackupProgress(BackupStage.encoding));
    final data = File('$staging/data.json');
    final jsonOutput = _JsonFileSink(data, check);
    try {
      final encoder = const JsonEncoder().startChunkedConversion(
        utf8.encoder.startChunkedConversion(jsonOutput),
      );
      encoder.add(payload);
      encoder.close();
    } finally {
      jsonOutput.close();
    }
    final entries = <String, String>{...paths, 'data.json': data.path};
    final integrity = <String, Object?>{};
    var completed = 0;
    for (final entry in entries.entries) {
      check();
      final file = File(entry.value);
      final digest = _HashSink();
      final hash = sha256.startChunkedConversion(digest);
      var crc = 0;
      var length = 0;
      await for (final chunk in file.openRead()) {
        check();
        hash.add(chunk);
        crc = getCrc32(chunk, crc);
        length += chunk.length;
      }
      hash.close();
      integrity[entry.key] = {
        'size': length,
        'sha256': digest.value.toString(),
      };
      var encodedPath = file.path;
      if (entry.key == 'data.json') {
        // archive's default encoder buffers each compressed member. Precompress
        // the potentially large chapter JSON to disk instead, in bounded reads.
        final compressed = File('$staging/data.deflate');
        final sink = compressed.openWrite();
        try {
          await for (final chunk in file.openRead().transform(
            ZLibEncoder(raw: true, level: 1),
          )) {
            check();
            sink.add(chunk);
            await sink.flush();
          }
        } finally {
          await sink.close();
        }
        encodedPath = compressed.path;
      }
      prepared.add((
        entry.key,
        encodedPath,
        length,
        crc,
        entry.key == 'data.json',
      ));
      port.send(
        BackupProgress(
          BackupStage.encoding,
          completedItems: ++completed,
          totalItems: entries.length,
        ),
      );
    }
    final manifest = ArchiveFile.string(
      'manifest.json',
      jsonEncode({
        'version': 1,
        'exportedAt': payload['exportedAt'],
        'files': integrity,
      }),
    )..compression = CompressionType.none;
    check();
    output = _CancellableOutput(outputPath, check);
    final encoder = ZipEncoder()..startEncode(output);
    completed = 0;
    final totalItems = prepared.length + 1;
    port.send(BackupProgress(BackupStage.packing, totalItems: totalItems));
    for (final (name, path, size, crc, compressed) in prepared) {
      check();
      // Open only the current entry: a large manga library must not exhaust
      // Android's file-descriptor limit before packing even begins.
      member =
          ArchiveFile.file(name, size, _PreparedContent(InputFileStream(path)))
            ..compression = compressed
                ? CompressionType.deflate
                : CompressionType.none
            ..crc32 = crc;
      try {
        encoder.add(member, autoClose: false);
      } finally {
        await member.close();
        member = null;
      }
      port.send(
        BackupProgress(
          BackupStage.packing,
          completedItems: ++completed,
          totalItems: totalItems,
          completedBytes: output.length,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    check();
    try {
      encoder.add(manifest);
    } finally {
      await manifest.close();
    }
    port.send(
      BackupProgress(
        BackupStage.packing,
        completedItems: totalItems,
        totalItems: totalItems,
        completedBytes: output.length,
      ),
    );
    check();
    encoder.endEncode();
  } catch (error) {
    result = switch (error) {
      BackupCancelledException() => 'cancelled',
      FileSystemException() => 'storage',
      FormatException() || JsonUnsupportedObjectError() => 'format',
      _ => 'failed',
    };
  } finally {
    if (output is _CancellableOutput) output.closing = true;
    try {
      await output?.close();
      await member?.close();
    } catch (_) {
      result = 'failed';
    }
    port.send(result);
  }
}

class _PreparedContent extends FileContentStream {
  _PreparedContent(super.stream);
  @override
  bool get isCompressed => true;
}

class _CancellableOutput extends OutputFileStream {
  _CancellableOutput(String path, this.check)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final void Function() check;
  bool closing = false;
  @override
  void flush() {
    if (!closing) check();
    super.flush();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    check();
    super.writeBytes(bytes, length: length);
  }
}

class _JsonFileSink implements Sink<List<int>> {
  _JsonFileSink(File file, this.check)
    : output = file.openSync(mode: FileMode.writeOnly);
  final RandomAccessFile output;
  final void Function() check;
  bool closed = false;
  @override
  void add(List<int> data) {
    check();
    output.writeFromSync(data);
  }

  @override
  void close() {
    if (!closed) {
      closed = true;
      output.closeSync();
    }
  }
}

class _HashSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) => value = digest;
  @override
  void close() {}
}
