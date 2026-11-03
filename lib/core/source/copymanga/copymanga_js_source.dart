import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/chapter.dart';
import '../../models/media_item.dart';
import '../../models/media_type.dart';
import '../../models/source_descriptor.dart';
import '../../models/source_exception.dart';
import '../../platform/platform_channel.dart';
import '../../storage/secure_store.dart';
import '../../text/zh_converter.dart';
import '../http_client.dart';
import '../js/js_runtime.dart';
import '../js/js_source.dart';
import '../rule_schema.dart';
import '../source_api.dart';
import '../tag_search.dart';
import '../windows_source_session.dart';
import 'copymanga_auth.dart';
import 'copymanga_preferences.dart';

/// Copy's optional account lives in native code, not in a downloadable rule.
class CopyMangaJsSource extends JsSource implements AccountProvider {
  factory CopyMangaJsSource({
    required SourceRule rule,
    required JsRuntime runtime,
    required SourceHttpClient http,
    required CopyMangaPreferences preferences,
    required SecureStore secureStore,
  }) {
    if (!supportsCopyMangaSettings(rule.descriptor.id, rule.descriptor.version)) {
      throw ArgumentError('拷贝漫画原生设置需要 1.1.0 或更新的规则');
    }
    // Account consent belongs to these rule bytes and inputs, not its claimed ID.
    // Updating/replacing them requires another explicit native login; old
    // credentials remain isolated and are never migrated to replacement code.
    final headers = rule.headers.keys.toList()..sort();
    final fingerprint = sha256.convert(utf8.encode(jsonEncode([
      rule.descriptor.id, rule.descriptor.version, rule.jsCode, rule.baseUrl,
      [for (final key in headers) [key, rule.headers[key]]],
      [for (final feed in rule.feeds) [feed.id, feed.name, feed.urlTemplate]],
    ]))).toString();
    final auth = CopyMangaAuth(http: http, settings: preferences, store: secureStore,
      ruleFingerprint: fingerprint);
    return CopyMangaJsSource._(rule, runtime, preferences, auth);
  }

  CopyMangaJsSource._(SourceRule rule, JsRuntime runtime, this.settings, this._auth)
      : super(rule: rule, runtime: runtime, http: CopyMangaHttpClient(_auth),
          requestOptions: () => settings.requestOptions) {
    _auth.onSessionChanged = () {
      _generation++;
      invalidateDetailCache();
    };
  }

  final CopyMangaPreferences settings;
  final CopyMangaAuth _auth;
  int _generation = 0;
  bool _websiteSessionBusy = false;

  @override
  SourceDescriptor get descriptor {
    final base = super.descriptor;
    return base.copyWith(requireLogin: false,
      capabilities: {...base.capabilities, SourceCapability.account});
  }

  @override
  bool get isLoggedIn => _auth.isLoggedIn;
  String? get accountName => _auth.account;
  @override
  Future<void> restoreSession() => _auth.restoreSession();
  @override
  Future<void> login(String account, String password) => _auth.login(account, password);
  @override
  Future<void> logout() => _auth.logout();

  Future<void> updateSetting(String key, Object value) async {
    _auth.revokePending();
    await settings.set(key, value);
    _auth.revokePending();
  }

  /// Explicit browser Save captures only a native cookie, never page-script data.
  Future<bool> openWebsiteSession() async {
    SourceException failure(String message) => SourceException(
      sourceId: 'copymanga', type: SourceErrorType.auth, message: message);
    if (_websiteSessionBusy) throw failure('网站登录窗口已打开');
    _websiteSessionBusy = true;
    _auth.revokePending();
    final generation = _generation;
    final apiDomain = settings.apiDomain;
    final webDomain = settings.value('webDomain') as String;
    final origin = 'https://$webDomain/';
    final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    Future<String?> cookies() => windows
        ? WindowsSourceSession.cookies('copymanga', origin)
        : platformChannel.ruleCookieHeader(origin, sourceId: 'copymanga');
    try {
      final userAgent = await _auth.userAgents.resolve() ?? '';
      final saved = windows
          ? await WindowsSourceSession.open(sourceId: 'copymanga', url: origin, userAgent: userAgent)
          : await platformChannel.openRuleSession(origin, userAgent, sourceId: 'copymanga');
      if (!saved) return false;
      final tokens = _cookieTokens(await cookies());
      if (tokens.isEmpty) {
        throw failure('网站未提供可读取的 token Cookie。若站点仅使用 localStorage 或请求头，请改用账号密码登录。');
      }
      // Move captured credentials into secure storage; do not leave a second
      // persistent credential in the general source-browser cookie jar.
      final expired = [
        'token=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure',
        for (final domain in {webDomain, webDomain.substring(webDomain.indexOf('.') + 1)})
          'token=; Domain=$domain; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure',
      ];
      if (windows) {
        await WindowsSourceSession.storeCookies('copymanga', origin, expired);
      } else {
        await platformChannel.storeRuleCookies(origin, expired, sourceId: 'copymanga');
      }
      if (_cookieTokens(await cookies()).isNotEmpty) throw failure('无法安全移除浏览器会话，请使用账号密码登录');
      if (tokens.length != 1) throw failure('网站返回多个不同的登录会话，请清理网站会话后重试');
      if (generation != _generation || apiDomain != settings.apiDomain ||
          webDomain != settings.value('webDomain')) {
        throw failure('登录期间线路或会话已更改，请重试');
      }
      await _auth.importWebsiteToken(tokens.single, apiDomain: apiDomain);
      return true;
    } on SourceException {
      rethrow;
    } catch (_) {
      throw failure('无法完成安全网站登录；请使用账号密码入口或检查当前平台的网站会话支持');
    } finally {
      _websiteSessionBusy = false;
    }
  }

  static Set<String> _cookieTokens(String? header) => {
    for (final entry in (header ?? '').split(';'))
      if (entry.trim().startsWith('token=') && entry.trim().substring(6).isNotEmpty)
        entry.trim().substring(6),
  };

  /// Only the browser link changes; source IDs, chapter IDs and cache keys do not.
  String websiteUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !copyMangaWebDomains.containsKey(uri.host)) return url;
    return uri.replace(scheme: 'https', host: settings.value('webDomain') as String,
      port: 443, userInfo: '').toString();
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    final generation = _generation;
    final result = await operation();
    if (generation != _generation) throw StateError('拷贝漫画会话或设置已更改，请重新加载');
    return result;
  }

  ZhConversionMode get _mode => switch (settings.value('languageConversion')) {
    's2t' => ZhConversionMode.s2t,
    't2s' => ZhConversionMode.t2s,
    _ => ZhConversionMode.off,
  };

  Future<MediaItem> _convertItem(MediaItem item) async {
    final mode = _mode;
    if (mode == ZhConversionMode.off) return item;
    final converter = await ZhConverter.instance();
    final json = item.toJson();
    for (final key in const ['title', 'author', 'description', 'status']) {
      if (json[key] case final String text) json[key] = converter.convert(text, mode);
    }
    json['tags'] = [for (final tag in item.tags) converter.convert(tag, mode)];
    return MediaItem.fromJson(json, sourceId: item.sourceId, fallbackType: item.type);
  }

  Future<List<MediaItem>> _convertItems(List<MediaItem> items) async {
    if (_mode == ZhConversionMode.off) return items;
    return [for (final item in items) await _convertItem(item)];
  }

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) =>
      _guard(() async => _convertItems(await super.discover(feed, page: page)));
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      _guard(() async => _convertItems(await super.search(keyword, page: page)));
  @override
  Future<List<MediaItem>> searchTagged(String keyword, {required List<String> tags, int page = 1}) =>
      _guard(() async => _convertItems(await super.searchTagged(keyword, tags: tags, page: page)));
  @override
  Future<MediaItem> detail(MediaItem item) =>
      _guard(() async => _convertItem(await super.detail(item)));
  @override
  Future<List<SearchTag>> searchTags() => _guard(() async {
    final tags = await super.searchTags();
    final mode = _mode;
    if (mode == ZhConversionMode.off) return tags;
    final converter = await ZhConverter.instance();
    return [for (final tag in tags)
      SearchTag(id: tag.id, label: converter.convert(tag.label, mode))];
  });

  @override
  Future<List<Chapter>> chapters(MediaItem item) => _guard(() async {
    final chapters = await super.chapters(item);
    final mode = _mode;
    if (mode == ZhConversionMode.off) return chapters;
    final converter = await ZhConverter.instance();
    return [for (final chapter in chapters) Chapter(
      sourceId: chapter.sourceId, remoteId: chapter.remoteId,
      title: converter.convert(chapter.title, mode), url: chapter.url,
      number: chapter.number, sortIndex: chapter.sortIndex,
      volumeTitle: chapter.volumeTitle == null ? null : converter.convert(chapter.volumeTitle!, mode),
      releaseDate: chapter.releaseDate, locked: chapter.locked, content: chapter.content,
    )];
  });

  @override
  Future<ChapterContent> content(Chapter chapter) => _guard(() async {
    final content = await super.content(chapter);
    final mode = _mode;
    final headers = await _auth.userAgents.headers(content.imageHeaders);
    final converter = mode == ZhConversionMode.off || content.comments.isEmpty
        ? null : await ZhConverter.instance();
    return content.copyWith(
      imageHeaders: headers,
      comments: converter == null ? content.comments : [for (final comment in content.comments) ChapterComment(
        author: converter.convert(comment.author, mode),
        text: converter.convert(comment.text, mode),
        replyTo: comment.replyTo == null ? null : converter.convert(comment.replyTo!, mode),
      )],
    );
  });

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }
}
