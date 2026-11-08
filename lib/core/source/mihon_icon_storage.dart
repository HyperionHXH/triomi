import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'http_client.dart';

/// Installed artwork is app data, not an evictable network/image cache. Each
/// package owns one bounded, decoded PNG; repository URLs never become paths.
class MihonIconStorage {
  const MihonIconStorage({required this.http});

  final SourceHttpClient http;
  static const maxBytes = 1024 * 1024;
  static const _maxPixels = 1024 * 1024;
  static const _deadline = Duration(seconds: 10);
  static final _tails = <String, Future<void>>{};

  static bool validPackageName(String package) =>
      package.length <= 255 &&
      RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$').hasMatch(package);

  static String? iconUrl(Object? value) {
    final uri = Uri.tryParse(value?.toString().trim() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }
    return uri.toString();
  }

  Future<T> _locked<T>(String package, Future<T> Function() action) async {
    if (!validPackageName(package)) {
      throw const FormatException('扩展包身份无效');
    }
    final previous = _tails[package];
    final release = Completer<void>();
    _tails[package] = release.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_tails[package], release.future)) {
        unawaited(_tails.remove(package));
      }
    }
  }

  Future<File> _file(String package) async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/mihon-extension-icons');
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FileSystemException('图标目录不是普通目录');
    }
    await root.create(recursive: true);
    final file = File('${root.path}/$package.png');
    final fileType = await FileSystemEntity.type(file.path, followLinks: false);
    if (fileType != FileSystemEntityType.notFound &&
        fileType != FileSystemEntityType.file) {
      throw const FileSystemException('图标不是普通文件');
    }
    return file;
  }

  Future<File?> _local(String package) async {
    final file = await _file(package);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length == 0 || length > maxBytes) return null;
    // Bound reads too, in case another process changes app data after stat.
    final input = await file.open();
    late Uint8List bytes;
    try {
      bytes = await input.read(length + 1);
      if (bytes.length != length) return null;
    } finally {
      await input.close();
    }
    // A corrupt file must not hide subsequently obtainable artwork forever.
    await _decode(bytes, encode: false);
    return file;
  }

  /// Reads without making any request. Corrupt/missing artwork is not a plugin
  /// failure, and no path supplied by backup or repository metadata is opened.
  Future<File?> local(String package) async {
    if (!validPackageName(package)) return null;
    try {
      return await _locked(package, () => _local(package));
    } catch (_) {
      return null;
    }
  }

  /// Keeps an existing good icon unless explicitly refreshing after a trusted
  /// installation. A failed download/decode/write never replaces old artwork.
  Future<File?> obtain(
    String package,
    String? url, {
    bool refresh = false,
  }) async {
    if (!validPackageName(package)) return null;
    try {
      return await _locked(package, () async {
        File? previous;
        try {
          previous = await _local(package);
        } catch (_) {
          // A corrupt file is replaceable, but never treated as saved artwork.
        }
        if (previous != null && !refresh) return previous;
        final address = iconUrl(url);
        if (address == null) return previous;
        try {
          final owner = SourceRequestCancellation();
          final png = await owner
              .run(() => _download(package, address))
              .timeout(
                _deadline,
                onTimeout: () {
                  owner.cancel('扩展图标下载超时');
                  throw TimeoutException('扩展图标下载超时');
                },
              );
          final file = await _file(package);
          final staging = await file.parent.createTemp('icon-');
          try {
            final candidate = File('${staging.path}/icon.png');
            await candidate.writeAsBytes(png, flush: true);
            await candidate.rename(file.path);
            await FileImage(file).evict();
            return file;
          } finally {
            await staging.delete(recursive: true);
          }
        } catch (_) {
          return previous;
        }
      });
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _download(String package, String url) async {
    final response = await http.downloadBytes(
      url,
      sourceId: 'mihon-icon:$package',
    );
    try {
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          (response.contentLength ?? 0) > maxBytes) {
        throw const FormatException('扩展图标响应无效或过大');
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.stream) {
        length += chunk.length;
        if (length > maxBytes) throw const FormatException('扩展图标超过 1 MiB');
        bytes.add(chunk);
      }
      if (length == 0) throw const FormatException('扩展图标为空');
      if (response.contentLength != null && length != response.contentLength) {
        throw const FormatException('扩展图标下载不完整');
      }
      return (await _decode(bytes.takeBytes(), encode: true))!;
    } finally {
      await response.close();
    }
  }

  /// Normalize the first frame to PNG so animated payloads cannot leave an
  /// unbounded multi-frame decoder running in every installed-plugin row.
  Future<Uint8List?> _decode(Uint8List bytes, {required bool encode}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width > 2048 ||
          descriptor.height > 2048 ||
          descriptor.width * descriptor.height > _maxPixels) {
        throw const FormatException('扩展图标尺寸无效或过大');
      }
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      if (!encode) return null;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null ||
          png.lengthInBytes == 0 ||
          png.lengthInBytes > maxBytes) {
        throw const FormatException('扩展图标编码无效或过大');
      }
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  /// Only called after the host and installation metadata confirm removal.
  Future<void> remove(String package) async {
    if (!validPackageName(package)) return;
    try {
      await _locked(package, () async {
        final file = await _file(package);
        if (await file.exists()) await file.delete();
        await FileImage(file).evict();
      });
    } catch (_) {
      // Artwork cleanup must not turn an already completed uninstall into a
      // reported plugin/trust failure. It is never used for uninstalled rows.
    }
  }
}
