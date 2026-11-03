import 'dart:convert';
import 'dart:math';

import '../http_client.dart';
import 'copymanga_preferences.dart';

/// APK command semantics. The public list is fetched once, without credentials.
class CopyMangaUserAgent {
  CopyMangaUserAgent(this.settings, this.http);
  final CopyMangaPreferences settings;
  final SourceHttpClient http;
  final _random = Random();
  Future<Map<String, List<String>>>? _pool;

  Future<Map<String, List<String>>> _loadPool() async {
    try {
      final response = await http.send(const SourceRequest(
        url: 'https://keiyoushi.github.io/user-agents/user-agents.json',
        followRedirects: false,
      ), sourceId: 'copymanga');
      if (response.statusCode != 200 || response.body.length > 262144) throw const FormatException('UA list');
      final data = jsonDecode(response.body);
      if (data is! Map) throw const FormatException('UA list');
      final result = <String, List<String>>{};
      for (final kind in const ['desktop', 'mobile']) {
        final raw = data[kind];
        if (raw is! List) throw const FormatException('UA list');
        final values = [for (final value in raw.take(256))
          if (value is String && value.isNotEmpty && value.length <= 2048 &&
              !RegExp(r'[\r\n\x00]').hasMatch(value)) value];
        if (values.isEmpty) throw const FormatException('UA list');
        result[kind] = values;
      }
      return result;
    } catch (_) {
      // These are the current Android plugin's documented offline pool values.
      return const {
        'desktop': [copyMangaUserAgent],
        'mobile': ['Mozilla/5.0 (Android 14; Mobile; rv:136.0) Gecko/136.0 Firefox/136.'],
      };
    }
  }

  /// Null delegates to the host; empty explicitly suppresses its default header.
  Future<String?> resolve() async {
    final value = settings.value('userAgent') as String;
    if (value == 'app') return null;
    if (value == 'none') return '';
    if (value == 'desktop' || value == 'mobile') {
      final pool = await (_pool ??= _loadPool());
      final values = pool[value]!;
      return values[_random.nextInt(values.length)];
    }
    return value == 'reset' ? copyMangaUserAgent : value;
  }

  Future<Map<String, String>> headers(Map<String, String> original) async {
    final value = await resolve();
    return {
      for (final entry in original.entries)
        if (entry.key.toLowerCase() != 'user-agent') entry.key: entry.value,
      'User-Agent': ?value,
    };
  }
}
