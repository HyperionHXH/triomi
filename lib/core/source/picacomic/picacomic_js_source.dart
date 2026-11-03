import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/chapter.dart';
import '../../models/media_item.dart';
import '../../models/source_descriptor.dart';
import '../../storage/secure_store.dart';
import '../http_client.dart';
import '../js/js_runtime.dart';
import '../js/js_source.dart';
import '../rule_schema.dart';
import '../source_api.dart';
import '../tag_search.dart';
import 'picacomic_client.dart';
import 'picacomic_preferences.dart';

class PicacomicJsSource extends JsSource implements AccountProvider {
  factory PicacomicJsSource({
    required SourceRule rule,
    required JsRuntime runtime,
    required SourceHttpClient http,
    required SecureStore secureStore,
    required PicacomicPreferences preferences,
  }) {
    if (rule.descriptor.id != 'picacomic' ||
        rule.baseUrl != picaApi ||
        rule.descriptor.nsfw != true ||
        !rule.descriptor.requireLogin) {
      throw const RuleFormatException('哔咔规则必须声明官方 API、登录要求和 NSFW 分级');
    }
    final headers = rule.headers.keys.toList()..sort();
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              rule.descriptor.id,
              rule.descriptor.version,
              rule.jsCode,
              rule.baseUrl,
              [
                for (final key in headers) [key, rule.headers[key]],
              ],
              [
                for (final feed in rule.feeds)
                  [feed.id, feed.name, feed.urlTemplate],
              ],
            ]),
          ),
        )
        .toString();
    return PicacomicJsSource._(
      rule,
      runtime,
      preferences,
      PicacomicClient(
        http: http,
        store: secureStore,
        fingerprint: fingerprint,
        quality: () => preferences.quality,
      ),
    );
  }

  PicacomicJsSource._(
    SourceRule rule,
    JsRuntime runtime,
    this.settings,
    this.client,
  ) : super(
        rule: rule,
        runtime: runtime,
        http: client,
        requestOptions: () => settings.requestOptions,
      ) {
    client.onChanged = invalidateDetailCache;
    client.restoreSession();
  }

  final PicacomicPreferences settings;
  final PicacomicClient client;

  @override
  SourceDescriptor get descriptor => super.descriptor.copyWith(
    requireLogin: true,
    capabilities: {...super.descriptor.capabilities, SourceCapability.account},
  );
  @override
  bool get isLoggedIn => client.isLoggedIn;
  @override
  Future<void> restoreSession() => client.restoreSession();
  @override
  Future<void> login(String account, String password) =>
      client.login(account, password);
  @override
  Future<void> logout() => client.logout();

  Future<void> updateSetting(String key, String value) async {
    client.revokePending();
    invalidateDetailCache();
    await settings.set(key, value);
    invalidateDetailCache();
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    final revision = client.revision;
    final result = await action();
    if (revision != client.revision) throw StateError('哔咔会话或设置已更改，请重新加载');
    return result;
  }

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) =>
      _guard(() => super.discover(feed, page: page));
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      _guard(() => super.search(keyword, page: page));
  @override
  Future<List<MediaItem>> searchTagged(
    String keyword, {
    required List<String> tags,
    int page = 1,
  }) => _guard(() => super.searchTagged(keyword, tags: tags, page: page));
  @override
  Future<List<SearchTag>> searchTags() => _guard(super.searchTags);
  @override
  Future<MediaItem> detail(MediaItem item) => _guard(() => super.detail(item));
  @override
  Future<List<Chapter>> chapters(MediaItem item) =>
      _guard(() => super.chapters(item));
  @override
  Future<ChapterContent> content(Chapter chapter) =>
      _guard(() => super.content(chapter));

  @override
  void dispose() {
    client.close();
    super.dispose();
  }
}
