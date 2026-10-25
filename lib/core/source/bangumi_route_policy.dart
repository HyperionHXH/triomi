import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/preferences.dart';

/// Only public Bangumi data and explicitly supported cover paths are routed.
/// Account URLs, custom sources and credentials never enter this policy.
class BangumiRoutePolicy {
  const BangumiRoutePolicy({this.mirrorEnabled = true});

  final bool mirrorEnabled;
  static const officialV0 = 'https://api.bgm.tv/v0';
  static const officialNext = 'https://next.bgm.tv/p1';
  static const mirrorV0 = 'https://api.bgmapi.com/v0';
  static const mirrorNext = 'https://api.kazumi.fyi/p1';
  static const mirrorPopular =
      'https://api.kazumi.fyi/kazumi/v1/popular/subjects';

  String get v0 => mirrorEnabled ? mirrorV0 : officialV0;
  String get p1 => mirrorEnabled ? mirrorNext : officialNext;
  String get calendar => '$p1/calendar';
  String get popular =>
      mirrorEnabled ? mirrorPopular : '$officialNext/trending/subjects';

  /// The mirror protects comments with private application signatures. Keep
  /// real subject/episode discussion identities on the anonymous official API;
  /// acceleration uses ECH there, never a different review feed.
  String get comments => officialNext;

  static final _picturePath = RegExp(
    r'^/(?:r/\d+(?:x\d+)?/)?pic/(?:cover|crt)/',
  );

  String coverRequestUrl(String url) {
    if (!mirrorEnabled) return url;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasPort) {
      return url;
    }
    final picture =
        uri.host == 'lain.bgm.tv' &&
        !uri.hasQuery &&
        _picturePath.hasMatch(uri.path);
    final parts = uri.pathSegments;
    final apiPicture =
        uri.host == 'api.bgm.tv' &&
        parts.length == 4 &&
        parts[0] == 'v0' &&
        const {'subjects', 'characters', 'persons'}.contains(parts[1]) &&
        (int.tryParse(parts[2]) ?? 0) > 0 &&
        parts[3] == 'image' &&
        (!uri.hasQuery ||
            (uri.queryParametersAll.length == 1 &&
                uri.queryParametersAll['type']?.length == 1 &&
                const {
                  'large',
                  'common',
                  'medium',
                  'small',
                  'grid',
                }.contains(uri.queryParameters['type'])));
    if (!picture && !apiPicture) return url;
    return Uri.https('wsrv.nl', '/', {
      'url': '${uri.host}${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
      if (uri.path.toLowerCase().endsWith('.gif')) 'n': '-1',
    }).toString();
  }

  /// Exact anonymous official API paths which may use ECH. This is never a
  /// general URL rewrite and excludes accounts, collections and writes.
  bool permitsEch(Uri uri, String method, Iterable<String> headerNames) {
    if (!mirrorEnabled ||
        uri.scheme != 'https' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        headerNames.any(
          (key) => const {
            'authorization',
            'cookie',
            'cookie2',
            'proxy-authorization',
            'x-appid',
            'x-signature',
          }.contains(key.toLowerCase()),
        )) {
      return false;
    }
    if (uri.queryParameters.keys.any(
      (key) => !const {'limit', 'offset', 'type'}.contains(key),
    )) {
      return false;
    }
    if (uri.host == 'next.bgm.tv' && method == 'GET') {
      return uri.path == '/p1/calendar' ||
          uri.path == '/p1/trending/subjects' ||
          RegExp(r'^/p1/(?:subjects|characters|episodes)/\d+(?:/comments)?$')
              .hasMatch(uri.path);
    }
    return false;
  }
}

abstract interface class BangumiImageRoutingClient {
  BangumiRoutePolicy get bangumiRoutes;
}

class BangumiMirrorController extends Notifier<bool> {
  static const key = 'network.bangumiMirrorEnabled';

  @override
  bool build() => ref.watch(preferencesProvider).get<bool>(key) ?? true;

  Future<void> setEnabled(bool enabled) async {
    await ref.read(preferencesProvider).set(key, enabled);
    state = enabled;
  }
}

final bangumiMirrorEnabledProvider =
    NotifierProvider<BangumiMirrorController, bool>(
      BangumiMirrorController.new,
    );

final bangumiRoutePolicyProvider = Provider<BangumiRoutePolicy>(
  (ref) => BangumiRoutePolicy(
    mirrorEnabled: ref.watch(bangumiMirrorEnabledProvider),
  ),
);
