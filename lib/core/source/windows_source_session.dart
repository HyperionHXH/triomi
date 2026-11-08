import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Dedicated application WebView2 stores, never the user's Edge/browser jar.
/// Native CookieManager returns only cookies applicable to the exact HTTPS URL,
/// including HTTPOnly cookies; no page script supplies authentication data.
class WindowsSourceSession {
  static const _channel = MethodChannel('triomi/windows-web-session');

  /// A separate native controller owns each resolve; the login window is never
  /// reused or closed. WebView2 shares only this source's on-disk profile.
  static Future<void> startVideo({
    required int id,
    required String sourceId,
    required String sourceUrl,
    required String url,
    required String userAgent,
    required String script,
    String? referer,
    bool Function()? isCancelled,
  }) async {
    final source = Uri.parse(sourceUrl);
    final support = await getApplicationSupportDirectory();
    if (isCancelled?.call() == true) return;
    final key = sha256.convert(utf8.encode('$sourceId\n${source.origin}'));
    await _channel.invokeMethod<void>('startVideo', {
      'id': id,
      'url': url,
      'origin': source.origin,
      'profile': '${support.path}/windows-source-sessions/$key',
      'userAgent': userAgent,
      'script': script,
      'referer': ?referer,
    });
  }

  static Future<void> closeVideo(int id) =>
      _channel.invokeMethod<void>('closeVideo', {'id': id});

  static Uri _https(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw StateError('站点会话仅支持 HTTPS 地址');
    }
    return uri;
  }

  static Future<Map<String, Object>> _sourceArgs(
    String sourceId,
    String url,
  ) async {
    final uri = _https(url);
    final support = await getApplicationSupportDirectory();
    final key = sha256.convert(utf8.encode('$sourceId\n${uri.origin}'));
    return {
      'url': uri.toString(),
      'origin': uri.origin,
      'profile': '${support.path}/windows-source-sessions/$key',
    };
  }

  static Future<bool> open({
    required String sourceId,
    required String url,
    required String userAgent,
  }) async {
    final args = await _sourceArgs(sourceId, url);
    final result = await _channel.invokeMapMethod<String, Object?>('open', {
      ...args,
      'userAgent': userAgent,
    });
    return result?['saved'] == true;
  }

  static Future<String?> cookies(String sourceId, String url) async => _channel
      .invokeMethod<String>('cookies', await _sourceArgs(sourceId, url));

  /// Only real HTTP response Set-Cookie headers enter this path. Browser pages
  /// have no callable channel and cannot replace the host's cookie capture.
  static Future<void> storeCookies(
    String sourceId,
    String url,
    List<String> values,
  ) async {
    final uri = _https(url);
    final parsed = <Map<String, Object>>[];
    for (final value in values) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        if (cookie.name.startsWith('__Secure-') && !cookie.secure) continue;
        if (cookie.name.startsWith('__Host-') &&
            (!cookie.secure || cookie.domain != null || cookie.path != '/')) {
          continue;
        }
        final domain = cookie.domain
            ?.replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        if (domain != null &&
            uri.host != domain &&
            !uri.host.endsWith('.$domain')) {
          continue;
        }
        final lastSlash = uri.path.lastIndexOf('/');
        final defaultPath = lastSlash <= 0
            ? '/'
            : uri.path.substring(0, lastSlash);
        final expiry = cookie.maxAge != null
            ? DateTime.now().add(Duration(seconds: cookie.maxAge!))
            : cookie.expires;
        parsed.add({
          'name': cookie.name,
          'value': cookie.value,
          'domain': cookie.domain ?? uri.host,
          'path': cookie.path?.startsWith('/') == true
              ? cookie.path!
              : defaultPath,
          'secure': cookie.secure,
          'httpOnly': cookie.httpOnly,
          if (expiry != null) 'expires': expiry.millisecondsSinceEpoch / 1000,
        });
      } on FormatException {
        // Invalid server cookies are ignored, never exported or logged.
      }
    }
    if (parsed.isEmpty) return;
    await _channel.invokeMethod<void>('store', {
      ...await _sourceArgs(sourceId, url),
      'cookies': parsed,
    });
  }

  /// Reads the exact media URL from the source's approved login store.
  /// [sourceUrl] is host-owned source/session context, never a URL reported by
  /// the media page. In particular, a CDN URL must not select a different jar.
  /// The native CookieManager alone applies domain, path and Secure rules.
  static Future<String?> videoCookies(
    String url, {
    required String sourceId,
    required String sourceUrl,
  }) async {
    final uri = Uri.tryParse(url);
    final source = Uri.tryParse(sourceUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        source == null ||
        source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      // HTTP/anonymous sources remain playable, but never receive HTTPS login
      // cookies or credentials from the old shared video-webview store.
      return null;
    }
    return _channel.invokeMethod<String>('videoCookies', {
      ...await _sourceArgs(sourceId, sourceUrl),
      'url': uri.toString(),
    });
  }
}
