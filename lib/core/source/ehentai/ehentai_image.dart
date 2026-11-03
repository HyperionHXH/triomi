import 'package:html/parser.dart' as html;

import '../../models/media_type.dart';
import '../../models/source_exception.dart';
import '../http_client.dart';

const ehentaiBase = 'https://e-hentai.org';

/// Portable image references point to the site's stable per-page identity,
/// not an expiring CDN URL. Resolve only when reader/download/save asks for it.
bool isEhentaiImagePage(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'e-hentai.org' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      RegExp(r'^/s/[a-f0-9]+/[1-9][0-9]*-[1-9][0-9]*$').hasMatch(uri.path);
}

SourceException _error(String message, SourceErrorType type) =>
    SourceException(sourceId: 'ehentai', type: type, message: message);

Future<String> resolveEhentaiImage(
  SourceHttpClient http,
  String pageUrl,
) async {
  if (!isEhentaiImagePage(pageUrl)) {
    throw _error('E-Hentai 图片页地址无效', SourceErrorType.parse);
  }
  final response = await http.send(
    SourceRequest(
      url: pageUrl,
      followRedirects: false,
      checkStatus: false,
      headers: const {'Referer': '$ehentaiBase/', 'User-Agent': 'Mozilla/5.0'},
    ),
    sourceId: 'ehentai',
  );
  if (response.statusCode != 200) {
    throw _error(
      'E-Hentai 图片页返回 HTTP ${response.statusCode}',
      switch (response.statusCode) {
        401 || 403 => SourceErrorType.auth,
        404 => SourceErrorType.notFound,
        429 || 509 => SourceErrorType.rateLimited,
        _ => SourceErrorType.network,
      },
    );
  }
  if (response.body.length > 2 * 1024 * 1024) {
    throw _error('E-Hentai 图片页超过安全限制', SourceErrorType.parse);
  }
  final document = html.parse(response.body);
  for (final element in document.querySelectorAll('script, style')) {
    element.remove();
  }
  final text = document.body?.text ?? '';
  if (RegExp(
    r'(?:exceeded|reached).*?(?:limit|quota)|temporarily banned',
    caseSensitive: false,
  ).hasMatch(text)) {
    throw _error('E-Hentai 图片额度已用尽或访问暂时受限，请稍后重试', SourceErrorType.rateLimited);
  }
  if (document.querySelector('#challenge-form, #challenge-running') != null ||
      RegExp(
        r'Just a moment|Attention Required|verify.*human',
        caseSensitive: false,
      ).hasMatch(document.querySelector('title')?.text ?? '')) {
    throw _error('E-Hentai 要求站点验证，本适配不绕过验证', SourceErrorType.auth);
  }
  final value = document.querySelector('img#img')?.attributes['src'];
  if (value == null || value.trim().isEmpty) {
    throw _error('E-Hentai 未返回可读取图片，可能已删除或需要网站登录', SourceErrorType.auth);
  }
  final uri = Uri.tryParse(Uri.parse(pageUrl).resolve(value).toString());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasFragment ||
      uri.host == 'exhentai.org' ||
      uri.host.endsWith('.exhentai.org') ||
      uri.path.startsWith('/s/') ||
      RegExp(r'[\s\\]').hasMatch(value)) {
    throw _error('E-Hentai 返回不支持的图片地址（仅 HTTPS）', SourceErrorType.parse);
  }
  if (RegExp(
    r'/(?:g/)?509\.(?:gif|jpg|png)$',
    caseSensitive: false,
  ).hasMatch(uri.path)) {
    throw _error('E-Hentai 图片额度已用尽，请稍后重试', SourceErrorType.rateLimited);
  }
  return uri.toString();
}
