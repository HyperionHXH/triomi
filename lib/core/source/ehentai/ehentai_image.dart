import 'dart:convert';

import '../../models/media_type.dart';
import '../../models/source_exception.dart';
import '../http_client.dart';
import 'ehentai_filters.dart';
import 'ehentai_network.dart';
import 'ehentai_parsers.dart';
import 'ehentai_preferences.dart';

/// Portable image references point to the site's stable per-page identity
/// (`https://<e-hentai|exhentai>.org/s/<hash>/<gid>-<n>`), not an expiring
/// CDN URL. Bytes are resolved lazily when the reader/download/save asks.
bool isEhentaiImagePage(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      (uri.host == ehentaiDomain || uri.host == exhentaiDomain) &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      RegExp(r'^/s/[a-f0-9]+/[1-9][0-9]*-[1-9][0-9]*$').hasMatch(uri.path);
}

final _quotaText = RegExp(
  r'(?:exceeded|reached).*?(?:limit|quota)',
  caseSensitive: false,
);
final _quotaImage = RegExp(r'/(?:g/)?509\.(?:gif|jpg|png)$', caseSensitive: false);
final _reloadKey = RegExp(r'''return\s+nl\(['"]([^'"]+)['"]\)''');
const _imageAccept = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';

SourceException _quotaExhausted() => ehentaiError(
  'E-Hentai 图片额度已用尽，请稍后重试',
  SourceErrorType.rateLimited,
);

/// Only HTTPS image URLs; HAtH nodes may use custom ports. Original images
/// come from the site's `/fullimg/` endpoint, which redirects to a node.
Uri _validatedImageUri(String value) {
  final uri = Uri.tryParse(value);
  final site = uri != null &&
      (uri.host == ehentaiDomain ||
          uri.host == exhentaiDomain ||
          uri.host.endsWith('.$ehentaiDomain') ||
          uri.host.endsWith('.$exhentaiDomain'));
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535 ||
      (uri.port != 443 && !uri.host.endsWith('.hath.network')) ||
      !RegExp(
        r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$',
        caseSensitive: false,
      ).hasMatch(uri.host) ||
      RegExp(r'^[0-9.]+$').hasMatch(uri.host) ||
      uri.host.endsWith('.localhost') ||
      uri.host.endsWith('.local') ||
      uri.hasFragment ||
      (site && !uri.path.startsWith('/fullimg')) ||
      uri.path.startsWith('/s/') ||
      RegExp(r'[\s\\]').hasMatch(value)) {
    throw ehentaiError('E-Hentai 返回不支持的图片地址（仅 HTTPS）', SourceErrorType.parse);
  }
  if (_quotaImage.hasMatch(uri.path)) throw _quotaExhausted();
  return uri;
}

/// Android `resolveImageUrl`: viewer page → `img#img` (or `/fullimg/` when
/// original quality is selected and the login cookies are present).
Future<String> resolveEhentaiImage(
  EhentaiNetwork network,
  String pageUrl,
) async {
  if (!isEhentaiImagePage(pageUrl)) {
    throw ehentaiError('E-Hentai 图片页地址无效', SourceErrorType.parse);
  }
  final cached = network.cachedImageUrl(pageUrl);
  if (cached != null) return cached;
  final page = await network.fetchPageHtmlWithRetry(pageUrl);
  if (page.html.length > 2 * 1024 * 1024) {
    throw ehentaiError('E-Hentai 图片页超过安全限制', SourceErrorType.parse);
  }
  final document = parseEhentaiHtml(page.html);
  final scriptless = parseEhentaiHtml(page.html);
  for (final element in scriptless.querySelectorAll('script, style')) {
    element.remove();
  }
  if (_quotaText.hasMatch(scriptless.body?.text ?? '')) {
    throw ehentaiError(
      'E-Hentai 图片额度已用尽或访问暂时受限，请稍后重试',
      SourceErrorType.rateLimited,
    );
  }
  if (document.querySelector('#challenge-form, #challenge-running') != null ||
      RegExp(
        r'Just a moment|Attention Required|verify.*human',
        caseSensitive: false,
      ).hasMatch(ehText(document.querySelector('title')))) {
    throw ehentaiError('E-Hentai 要求站点验证，本适配不绕过验证', SourceErrorType.auth);
  }
  final String value;
  try {
    value = parseEhentaiImageUrl(
      document,
      page.url,
      wantOriginal: network.wantOriginal,
    );
  } on FormatException {
    throw ehentaiError(
      'E-Hentai 未返回可读取图片，可能已删除或需要网站登录',
      SourceErrorType.auth,
    );
  }
  final resolved = _validatedImageUri(value).toString();
  network.cacheImageUrl(pageUrl, resolved);
  return resolved;
}

/// Android `EhentaiInterceptor.refreshImageUrl`: re-read the viewer page and
/// ask its `nl(key)` reload endpoint for another H@H node.
Future<String?> _refreshImageUrl(
  EhentaiNetwork network,
  String viewerUrl, {
  required bool preferOriginal,
}) async {
  try {
    final viewer = Uri.parse(viewerUrl);
    final referer = {'Referer': '${viewer.scheme}://${viewer.host}/'};
    final page = await network.get(viewerUrl, headers: referer);
    if (page.statusCode < 200 || page.statusCode >= 300) return null;
    final document = parseEhentaiHtml(page.body);
    if (preferOriginal) {
      final original = parseEhentaiOriginalLink(document, viewerUrl);
      if (original != null) return _validatedImageUri(original).toString();
    }
    final key = _reloadKey.firstMatch(page.body)?.group(1);
    if (key == null) return null;
    final reloadUrl = ehentaiAddQueryParameter(viewerUrl, 'nl', key);
    final reload = await network.get(reloadUrl, headers: referer);
    if (reload.statusCode < 200 || reload.statusCode >= 300) return null;
    final img = parseEhentaiHtml(reload.body).querySelector('img#img[src]');
    final src = img == null ? '' : ehAbsUrl(reloadUrl, img.attributes['src']);
    return src.isEmpty ? null : _validatedImageUri(src).toString();
  } on Object {
    if (SourceRequestCancellation.current?.cancelled == true) rethrow;
    return null;
  }
}

/// Lazy page bytes for the reader, downloads and Save Image. Applies
/// Android's image retry policy (403 unless banned, 404, 429, 5xx, IO) with
/// exponential back-off and `nl()` refresh, honouring cancellation.
Future<List<int>> fetchEhentaiImageBytes(
  EhentaiNetwork network,
  String viewerUrl,
) async {
  network.checkCancelled();
  var imageUrl = await resolveEhentaiImage(network, viewerUrl);
  final retryableHost = isEhentaiImageHost(Uri.parse(imageUrl).host);
  var retryNumber = 0;
  while (true) {
    network.checkCancelled();
    SourceResponse response;
    try {
      response = await network.get(
        imageUrl,
        bytes: true,
        headers: {'Referer': viewerUrl, 'Accept': _imageAccept},
        validateHop: (target) => _validatedImageUri(target.toString()),
      );
    } on Object catch (error) {
      if (!retryableHost ||
          !EhentaiRetryPolicy.isRetryableNetworkFailure(error) ||
          retryNumber >= EhentaiRetryPolicy.maxRetries) {
        rethrow;
      }
      retryNumber++;
      await network.wait(EhentaiRetryPolicy.retryDelay(retryNumber));
      final tls = '$error'.toLowerCase().contains('handshake');
      final refreshed = await _refreshImageUrl(
        network,
        viewerUrl,
        preferOriginal: tls || retryNumber % 4 == 0,
      );
      if (refreshed != null) {
        network.cacheImageUrl(viewerUrl, refreshed);
        imageUrl = refreshed;
      }
      continue;
    }
    final status = response.statusCode;
    if (_quotaImage.hasMatch(Uri.parse(response.url).path)) {
      throw _quotaExhausted();
    }
    if (status >= 200 && status < 300) {
      return response.bodyBytes ?? utf8.encode(response.body);
    }
    final body = status == 403
        ? utf8.decode(
            (response.bodyBytes ?? const <int>[]).take(64 * 1024).toList(),
            allowMalformed: true,
          )
        : '';
    if (retryableHost &&
        EhentaiRetryPolicy.isRetryableImageResponse(status, body) &&
        retryNumber < EhentaiRetryPolicy.maxRetries) {
      retryNumber++;
      await network.wait(EhentaiRetryPolicy.retryDelay(retryNumber));
      final refreshed = await _refreshImageUrl(
        network,
        viewerUrl,
        preferOriginal: retryNumber % 4 == 0,
      );
      if (refreshed != null) {
        network.cacheImageUrl(viewerUrl, refreshed);
        imageUrl = refreshed;
      }
      continue;
    }
    throw ehentaiError(
      status == 403 && EhentaiRetryPolicy.isExplicitlyBlocked(body)
          ? 'E-Hentai 暂时限制了当前网络出口。请等待几十秒后重试，或更换 Clash 节点；不要连续刷新关注列表。'
          : 'HTTP $status',
      status == 403 && EhentaiRetryPolicy.isExplicitlyBlocked(body)
          ? SourceErrorType.rateLimited
          : ehentaiStatusType(status),
      statusCode: status,
    );
  }
}
