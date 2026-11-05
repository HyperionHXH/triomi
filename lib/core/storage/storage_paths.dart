import 'dart:io';

import 'package:path/path.dart' as p;

/// Win32 extended-length paths preserve all 256-bit storage identities even
/// when the user profile/storage root plus chapter hierarchy exceeds MAX_PATH.
/// Only filesystem calls use this spelling; identity checks/URIs strip it.
String storageFilePath(String path) {
  if (!Platform.isWindows) return path;
  path = storagePathIdentity(path);
  final absolute = p.windows.normalize(p.windows.absolute(path));
  return absolute.startsWith(r'\\')
      ? '${r'\\?\UNC\'}${absolute.substring(2)}'
      : '${r'\\?\'}$absolute';
}

/// Canonical comparison and file-URI spelling, independent of Win32 API prefix.
String storagePathIdentity(String path) {
  if (Platform.isWindows) {
    path = path.replaceAll('/', r'\');
    if (path.startsWith(r'\\?\UNC\')) {
      path = '${r'\\'}${path.substring(8)}';
    } else if (path.startsWith(r'\\?\')) {
      path = path.substring(4);
    }
  }
  return p.normalize(p.absolute(path));
}
