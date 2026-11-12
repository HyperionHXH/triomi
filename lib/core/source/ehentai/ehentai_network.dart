import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/media_type.dart';
import '../../models/source_exception.dart';
import '../http_client.dart';
import 'ehentai_parsers.dart';
import 'ehentai_preferences.dart';

const ehentaiSourceId = 'ehentai';

SourceException ehentaiError(
  String message,
  SourceErrorType type, {
  int? statusCode,
  Object? cause,
}) => SourceException(
  sourceId: ehentaiSourceId,
  type: type,
  message: message,
  statusCode: statusCode,
  cause: cause,
);

/// Android `EhentaiRetryPolicy`: retry rules shared by page and H@H image
/// requests, `500ms * 2^(n-1)` capped at 15 s.
abstract final class EhentaiRetryPolicy {
  static const maxRetryDelay = Duration(milliseconds: 15000);

  /// Android retries until the coroutine is cancelled. iOS image loads have
  /// no owner that cancels them when a page scrolls away, so the loop is
  /// bounded (≈ 60 s of back-off) and also stops at [SourceRequestCancellation].
  static const maxRetries = 8;

  static const _permanentBlockMarkers = [
    'temporarily banned',
    'permanently banned',
    'your ip address has been banned',
    'your ip has been banned',
    'ip address has been banned',
    'excessive request rate',
    'access denied',
  ];

  static bool isRetryableImageResponse(int code, [String body = '']) {
    if (code == 403) return !isExplicitlyBlocked(body);
    return code == 404 || code == 429 || code >= 500;
  }

  static bool isExplicitlyBlocked(String body) {
    final normalized = body.toLowerCase();
    return _permanentBlockMarkers.any(normalized.contains);
  }

  /// Android retries only `IOException`s; errors raised by the extension
  /// itself (login page, ban, parse, unsupported proxy) are final. Here a
  /// transport failure is a Dio/timeout error, possibly wrapped by
  /// `SourceException.wrap` in the HTTP client.
  static bool isRetryableNetworkFailure(Object error) {
    if (SourceRequestCancellation.current?.cancelled == true) return false;
    final transport = error is SourceException ? error.cause : error;
    if (transport is! DioException && transport is! TimeoutException) {
      return false;
    }
    if (transport is DioException &&
        transport.type == DioExceptionType.cancel) {
      return false;
    }
    final text = '$transport'.toLowerCase();
    if (text.contains('failed host lookup') ||
        text.contains('no address associated') ||
        text.contains('nodename nor servname')) {
      return false; // UnknownHostException
    }
    if (text.contains('connection refused') ||
        text.contains('actively refused')) {
      return false;
    }
    return true;
  }

  static bool isRetryablePageFailure(Object error) {
    if (isRetryableNetworkFailure(error)) return true;
    final message = error is SourceException ? error.message ?? '' : '$error';
    return RegExp(r'HTTP(?: error)? (?:429|5\d{2})').hasMatch(message);
  }

  static Duration retryDelay(int retryNumber) {
    final exponent = (retryNumber - 1).clamp(0, 5);
    final ms = 500 << exponent;
    return Duration(milliseconds: ms > 15000 ? 15000 : ms);
  }
}

/// OkHttp `awaitSuccess` failure (`HTTP error <code>`).
class _EhentaiHttpStatus extends SourceException {
  const _EhentaiHttpStatus(int code, SourceErrorType type)
    : super(
        sourceId: ehentaiSourceId,
        type: type,
        message: 'HTTP error $code',
        statusCode: code,
      );
}

SourceErrorType ehentaiStatusType(int code) => switch (code) {
  401 => SourceErrorType.auth,
  403 => SourceErrorType.permission,
  404 || 410 => SourceErrorType.notFound,
  429 || 509 => SourceErrorType.rateLimited,
  _ => SourceErrorType.network,
};

bool isEhentaiImageHost(String host) =>
    host == 'hath.network' ||
    host.endsWith('.hath.network') ||
    host == 'ehgt.org' ||
    host.endsWith('.ehgt.org');

class _JarCookie {
  _JarCookie(this.name, this.value, this.domain, this.expiresAt);
  final String name;
  final String value;
  final String domain;
  final DateTime? expiresAt;
}

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun',
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// Android `EhentaiCookieJar`: session cookies the site sets (`sk`, `nw`,
/// refreshed `igneous`, ...) are kept in memory only, never persisted.
class EhentaiCookieJar {
  final _cookies = <String, _JarCookie>{};

  void save(Uri url, String? setCookieHeader) {
    if (setCookieHeader == null || setCookieHeader.isEmpty) return;
    for (final raw in setCookieHeader.split(
      RegExp(r',\s*(?=[^;,=\s]+=)'),
    )) {
      final parts = raw.split(';');
      final pair = parts.first;
      final index = pair.indexOf('=');
      if (index <= 0) continue;
      final name = pair.substring(0, index).trim();
      final value = pair.substring(index + 1).trim();
      var domain = url.host;
      DateTime? expires;
      for (final attribute in parts.skip(1)) {
        final separator = attribute.indexOf('=');
        final key = (separator < 0 ? attribute : attribute.substring(0, separator))
            .trim()
            .toLowerCase();
        final attributeValue = separator < 0
            ? ''
            : attribute.substring(separator + 1).trim();
        if (key == 'domain' && attributeValue.isNotEmpty) {
          final candidate = attributeValue.replaceFirst(RegExp(r'^\.'), '');
          if (url.host == candidate || url.host.endsWith('.$candidate')) {
            domain = candidate;
          }
        } else if (key == 'max-age') {
          final seconds = int.tryParse(attributeValue);
          if (seconds != null) {
            expires = DateTime.now().add(Duration(seconds: seconds));
          }
        } else if (key == 'expires' && expires == null) {
          final match = RegExp(
            r'(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4}) (\d{1,2}):(\d{2}):(\d{2})',
          ).firstMatch(attributeValue);
          final month = match == null
              ? -1
              : _months.indexOf(match[2]!.toLowerCase());
          if (match != null && month >= 0) {
            var year = int.parse(match[3]!);
            if (year < 100) year += year < 70 ? 2000 : 1900;
            expires = DateTime.utc(
              year,
              month + 1,
              int.parse(match[1]!),
              int.parse(match[4]!),
              int.parse(match[5]!),
              int.parse(match[6]!),
            );
          }
        }
      }
      final key = '$name\u0000$domain';
      if (expires != null && !expires.isAfter(DateTime.now())) {
        _cookies.remove(key);
      } else {
        _cookies[key] = _JarCookie(name, value, domain, expires);
      }
    }
  }

  List<(String, String)> load(Uri url) {
    final now = DateTime.now();
    _cookies.removeWhere(
      (_, cookie) => cookie.expiresAt != null && !cookie.expiresAt!.isAfter(now),
    );
    return [
      for (final cookie in _cookies.values)
        if (url.host == cookie.domain || url.host.endsWith('.${cookie.domain}'))
          (cookie.name, cookie.value),
    ];
  }

  void clear() => _cookies.clear();
}

/// Shared E-Hentai network state: login/session cookies (site hosts only),
/// User-Agent, optional HTTP proxy, page throttle and the viewer→image cache.
class EhentaiNetwork {
  EhentaiNetwork({
    required SourceHttpClient http,
    this.preferences,
    SourceHttpClient Function(String proxy)? proxyClientFactory,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
  }) : _http = http, // ignore: prefer_initializing_formals
       _proxyClientFactory = proxyClientFactory, // ignore: prefer_initializing_formals
       _sleep = sleep ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final SourceHttpClient _http;
  final EhentaiPreferences? preferences;
  final SourceHttpClient Function(String proxy)? _proxyClientFactory;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;
  final cookieJar = EhentaiCookieJar();

  String? _proxyKey;
  SourceHttpClient? _proxyClient;
  DateTime _lastPageRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Android `imageUrlCache` (512 entries, oldest evicted first).
  final _imageUrls = <String, String>{};
  static const _maxImageCacheEntries = 512;

  /// The network used by `DioSourceHttpClient.fetchBytes` for viewer pages.
  /// Set by the live `EhentaiSource`; anonymous defaults apply without one or
  /// when a different transport (e.g. a test client) asks.
  static EhentaiNetwork? active;

  static EhentaiNetwork forImages(SourceHttpClient transport) {
    final network = active;
    return network != null && identical(network._http, transport)
        ? network
        : EhentaiNetwork(http: transport);
  }

  String get userAgent => preferences?.userAgent ?? ehentaiDefaultUserAgent;
  bool get hasLoginCookie => preferences?.hasLoginCookie ?? false;
  bool get wantOriginal => (preferences?.wantOriginal ?? false) && hasLoginCookie;
  bool get isExhentai => preferences?.isExhentai ?? false;

  String? cachedImageUrl(String viewerUrl) => _imageUrls[viewerUrl];

  void cacheImageUrl(String viewerUrl, String imageUrl) {
    _imageUrls.remove(viewerUrl);
    _imageUrls[viewerUrl] = imageUrl;
    if (_imageUrls.length > _maxImageCacheEntries) {
      _imageUrls.remove(_imageUrls.keys.first);
    }
  }

  void clearImageCache() => _imageUrls.clear();

  /// HTTP(S) proxy for E-Hentai traffic only. SOCKS cannot be honoured by
  /// Dart's HttpClient and is reported instead of silently ignored.
  SourceHttpClient get client {
    final raw = preferences?.proxyUrl ?? '';
    final parsed = parseEhentaiProxy(raw);
    if (parsed.error != null) {
      throw ehentaiError(parsed.error!, SourceErrorType.network);
    }
    final proxy = parsed.proxy;
    if (proxy == null || _proxyClientFactory == null) return _http;
    if (_proxyKey != proxy) {
      _proxyClient?.close();
      _proxyClient = _proxyClientFactory(proxy);
      _proxyKey = proxy;
    }
    return _proxyClient!;
  }

  void resetProxy() {
    _proxyClient?.close();
    _proxyClient = null;
    _proxyKey = null;
  }

  void close() {
    resetProxy();
    if (identical(active, this)) active = null;
  }

  bool isSiteHost(String host) =>
      host == ehentaiDomain ||
      host.endsWith('.$ehentaiDomain') ||
      host == exhentaiDomain ||
      host.endsWith('.$exhentaiDomain');

  /// Request headers for [url]: configured UA, extra headers, then the
  /// session jar and login cookies — the latter only for site hosts.
  Map<String, String> headersFor(Uri url, Map<String, String> extra) {
    final headers = <String, String>{'User-Agent': userAgent, ...extra};
    if (isSiteHost(url.host)) {
      final login = preferences?.loginCookies ?? const <(String, String)>[];
      final names = {for (final (name, _) in login) name};
      final cookies = [
        for (final (name, value) in cookieJar.load(url))
          if (!names.contains(name)) '$name=$value',
        for (final (name, value) in login) '$name=$value',
      ];
      if (cookies.isNotEmpty) headers['Cookie'] = cookies.join('; ');
    } else {
      headers.removeWhere((key, _) => key.toLowerCase() == 'cookie');
    }
    return headers;
  }

  void checkCancelled() {
    if (SourceRequestCancellation.current?.cancelled == true) {
      throw ehentaiError('请求已取消', SourceErrorType.network);
    }
  }

  Future<void> wait(Duration delay) async {
    final owner = SourceRequestCancellation.current;
    if (owner == null) {
      await _sleep(delay);
    } else {
      await Future.any<void>([
        _sleep(delay),
        owner.token.whenCancel.then((_) {}),
      ]);
    }
    checkCancelled();
  }

  /// GET with manual redirects (≤ 5): cookies are re-evaluated per hop, so a
  /// redirect to another host never receives the site's login cookies.
  /// [validateHop] may veto each redirect target before it is requested.
  Future<SourceResponse> get(
    String url, {
    Map<String, String> headers = const {},
    bool bytes = false,
    void Function(Uri target)? validateHop,
  }) async {
    var uri = Uri.parse(url);
    for (var hop = 0; ; hop++) {
      checkCancelled();
      final response = await client.send(
        SourceRequest(
          url: uri.toString(),
          headers: headersFor(uri, headers),
          followRedirects: false,
          checkStatus: false,
          responseBytes: bytes,
        ),
        sourceId: ehentaiSourceId,
      );
      if (isSiteHost(uri.host)) {
        cookieJar.save(uri, response.headers['set-cookie']);
      }
      final status = response.statusCode;
      final location = response.headers['location'];
      if (const [301, 302, 303, 307, 308].contains(status) &&
          location != null &&
          location.isNotEmpty) {
        if (hop >= 5) {
          throw ehentaiError('Too many redirects: $url', SourceErrorType.network);
        }
        final target = uri.resolve(location);
        if (target.scheme != 'https' && target.scheme != 'http') {
          throw ehentaiError('Unsupported redirect', SourceErrorType.network);
        }
        validateHop?.call(target);
        uri = target;
        continue;
      }
      return SourceResponse(
        statusCode: status,
        body: response.body,
        bodyBytes: response.bodyBytes,
        url: uri.toString(),
        headers: response.headers,
      );
    }
  }

  /// Android `throttlePageRequest`.
  Future<void> throttlePageRequest() async {
    final interval = preferences?.requestIntervalMs ?? 0;
    if (interval <= 0) return;
    while (true) {
      final now = _clock();
      final waitMs =
          interval - now.difference(_lastPageRequestAt).inMilliseconds;
      if (waitMs <= 0) {
        _lastPageRequestAt = now;
        return;
      }
      await wait(Duration(milliseconds: waitMs));
    }
  }

  void checkExhentaiAccess() {
    if (isExhentai && !hasLoginCookie) {
      throw ehentaiError(
        'exhentai.org requires ipb_member_id / ipb_pass_hash / igneous in the source settings.',
        SourceErrorType.auth,
      );
    }
  }

  /// Android `fetchPageHtml`: throttle, page Referer, login/ban detection.
  Future<({String html, String url})> fetchPageHtml(String url) async {
    checkExhentaiAccess();
    await throttlePageRequest();
    final parsed = Uri.parse(url);
    final response = await get(
      url,
      headers: {'Referer': '${parsed.scheme}://${parsed.host}/'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _EhentaiHttpStatus(
        response.statusCode,
        ehentaiStatusType(response.statusCode),
      );
    }
    rejectEhentaiLoginPage(response.url, response.body);
    return (html: response.body, url: response.url);
  }

  /// Android `fetchPageHtmlWithRetry`.
  Future<({String html, String url})> fetchPageHtmlWithRetry(String url) async {
    Object? lastError;
    var retryNumber = 0;
    while (true) {
      try {
        return await fetchPageHtml(url);
      } on Object catch (error) {
        lastError = error;
        if (SourceRequestCancellation.current?.cancelled == true) rethrow;
        if (!EhentaiRetryPolicy.isRetryablePageFailure(error) ||
            retryNumber >= EhentaiRetryPolicy.maxRetries) {
          break;
        }
        retryNumber++;
        await wait(EhentaiRetryPolicy.retryDelay(retryNumber));
      }
    }
    final inner = lastError is SourceException
        ? lastError.message ?? lastError.type.label
        : '$lastError';
    throw SourceException(
      sourceId: ehentaiSourceId,
      type: lastError is SourceException
          ? lastError.type
          : SourceErrorType.network,
      statusCode: lastError is SourceException ? lastError.statusCode : null,
      cause: lastError,
      message: SourceException.sanitizeMessage(
        'Failed to fetch $url after ${retryNumber + 1} attempts ($inner). '
        'Check the network, User-Agent and 登录 Cookie settings.',
      ),
    );
  }
}

/// Android `rejectLoginPage`.
void rejectEhentaiLoginPage(String url, String html) {
  final lower = html.toLowerCase();
  if (lower.contains('temporarily banned') ||
      lower.contains('excessive request rate')) {
    throw ehentaiError(
      'E-Hentai 暂时限制了当前网络出口。请等待几十秒后重试，或更换 Clash 节点；不要连续刷新关注列表。',
      SourceErrorType.rateLimited,
    );
  }
  final document = parseEhentaiHtml(html);
  final title = ehText(document.querySelector('title'));
  final redirectedToLogin =
      url.contains('bounce_login.php') ||
      title.toLowerCase().contains('login') ||
      document.querySelector('form[name=ipb_login_form]') != null;
  if (!redirectedToLogin) return;
  final endpoint = url.contains('favorites.php')
      ? '收藏夹'
      : url.contains('/watched') || url.contains('/mytags')
      ? '关注标签'
      : Uri.tryParse(url)?.host == exhentaiDomain
      ? 'ExHentai'
      : 'E-Hentai 登录';
  throw ehentaiError(
    '$endpoint请求返回了登录页。请确认三个 Cookie 来自同一浏览器、同一 Clash 网络出口，且没有复制末尾标点；'
    '如果刚切换代理，请在当前出口重新登录并重新填写 ipb_member_id、ipb_pass_hash、igneous。',
    SourceErrorType.auth,
  );
}
