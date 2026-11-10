import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/chapter.dart';
import '../../core/models/video_resolve_cancellation.dart';
import '../../core/source/windows_source_session.dart';

class ResolvedDesktopVideo {
  const ResolvedDesktopVideo(
    this.url,
    this.headers, {
    this.mimeType,
    this.omitCookies = false,
  });
  final String url;
  final Map<String, String> headers;
  final String? mimeType;
  final bool omitCookies;
}

/// Each invocation owns a native controller in the source's dedicated profile.
/// Playback and download owners never cancel each other's browser or login UI.
Future<ResolvedDesktopVideo> resolveWindowsVideo(
  BuildContext context,
  PlaySource line, {
  required String sourceId,
  required String sourceUrl,
  VideoResolveCancellation? cancellation,
  bool allowBackground = false,
}) async {
  if (!context.mounted) throw VideoResolveCancelled('播放页面已关闭');
  final probe = _DesktopVideoProbe(
    line,
    sourceId,
    sourceUrl,
    cancellation ?? VideoResolveCancellation(),
    allowBackground,
  );
  try {
    return await probe.resolve();
  } finally {
    if (cancellation == null) probe.owner.dispose();
  }
}

class _DesktopVideoProbe with WidgetsBindingObserver {
  _DesktopVideoProbe(
    this.line,
    this.sourceId,
    this.sourceUrl,
    this.owner,
    this.allowBackground,
  );
  static const _channel = MethodChannel('triomi/windows-web-session');
  static final _owners = <int, _DesktopVideoProbe>{};
  static int _nextId = 0;
  final PlaySource line;
  final String sourceId;
  final String sourceUrl;
  final VideoResolveCancellation owner;
  final bool allowBackground;
  final _result = Completer<ResolvedDesktopVideo>();
  late final int _id = ++_nextId;
  Timer? _deadline;
  bool _capturing = false;
  bool _closed = false;
  static const _defaultAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  String _agent = _defaultAgent;

  static Uri? _httpUri(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
            const ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  static Future<void> _dispatch(MethodCall call) async {
    if (call.method != 'videoMessage' || call.arguments is! Map) return;
    final args = call.arguments as Map;
    final probe = _owners[args['id']];
    if (probe == null) return;
    if (args['error'] is String) {
      probe._fail(StateError(args['error'] as String));
    } else {
      await probe._onMessage(args['message']);
    }
  }

  void _fail(Object error) {
    if (!_result.isCompleted) _result.completeError(error);
  }

  void _cancel() => _fail(VideoResolveCancelled(owner.reason));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        !allowBackground &&
            (state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused)) {
      owner.cancel('应用窗口已隐藏，请显示窗口后继续网页解析');
    }
  }

  Future<ResolvedDesktopVideo> resolve() async {
    final target = _httpUri(line.url);
    final source = _httpUri(sourceUrl);
    if (target == null || source == null || sourceId.isEmpty) {
      throw StateError('播放页和来源必须是有效 HTTP(S) 地址');
    }
    final headers = {
      for (final e in line.headers.entries) e.key.toLowerCase(): e.value,
    };
    if (headers.keys.any((key) => key != 'user-agent' && key != 'referer')) {
      throw StateError('此来源需要桌面暂不支持的专用请求头，请更换来源');
    }
    _agent = headers['user-agent'] ?? _defaultAgent;
    if (_agent.isEmpty || _agent.contains(RegExp(r'[\r\n]'))) {
      throw StateError('来源 User-Agent 无效，请更换来源');
    }
    if (owner.isCancelled) throw VideoResolveCancelled(owner.reason);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null) didChangeAppLifecycleState(lifecycle);
    if (owner.isCancelled) throw VideoResolveCancelled(owner.reason);
    _channel.setMethodCallHandler(_dispatch);
    _owners[_id] = this;
    WidgetsBinding.instance.addObserver(this);
    owner.addListener(_cancel);
    _deadline = Timer(
      const Duration(seconds: 45),
      () => _fail(StateError('播放页未返回可播放地址，请重试或换来源')),
    );
    // Observe errors immediately, including while asynchronous environment
    // creation is pending. Close only after creation has acknowledged ownership.
    final start = WindowsSourceSession.startVideo(
      id: _id,
      sourceId: sourceId,
      sourceUrl: sourceUrl,
      url: line.url,
      isCancelled: () => owner.isCancelled || _closed,
      userAgent: _agent,
      referer: _httpUri(headers['referer']) == target
          ? null
          : _httpUri(headers['referer'])?.toString(),
      script:
          'window.__triomiLegacyParser = ${line.useLegacyParser};\n$_script',
    ).catchError(_fail);
    try {
      return await _result.future;
    } finally {
      _closed = true;
      _deadline?.cancel();
      _owners.remove(_id);
      WidgetsBinding.instance.removeObserver(this);
      owner.removeListener(_cancel);
      // Signal immediately too: pending native initialization must not navigate
      // a cancelled owner. The second close drains its eventual controller.
      await WindowsSourceSession.closeVideo(_id);
      await start;
      await WindowsSourceSession.closeVideo(_id);
    }
  }

  Future<void> _onMessage(dynamic message) async {
    if (_closed || _result.isCompleted || _capturing || owner.isCancelled) {
      return;
    }
    if (message is String) {
      try {
        message = jsonDecode(message);
      } catch (_) {
        return;
      }
    }
    if (message is! Map || message['type'] != 'triomi-media') return;
    final uri = _httpUri(message['url']?.toString());
    if (uri == null ||
        _httpUri(line.url)?.scheme == 'https' && uri.scheme != 'https') {
      return;
    }
    final hls = message['mimeType'] == 'application/vnd.apple.mpegurl';
    if (!hls &&
        message['evidence'] != 'video' &&
        !RegExp(
          r'\.(m3u8|mp4|m4v)$',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
      return;
    }
    final url = uri.toString();
    if (line.unavailableVideoUrls.contains(url)) {
      _fail(StateError('此线路返回了站点的加载失败占位，请更换播放列表'));
      return;
    }
    if (const [
      'googleads',
      'googlesyndication',
      'adposter',
    ].any(url.contains)) {
      return;
    }
    final page = _httpUri(message['page']?.toString());
    final referer = _httpUri(message['referer']?.toString());
    _capturing = true;
    try {
      final cookie = message['omitCookies'] == true
          ? null
          : await WindowsSourceSession.videoCookies(
              url,
              sourceId: sourceId,
              sourceUrl: sourceUrl,
            );
      if (_closed || _result.isCompleted || owner.isCancelled) return;
      _result.complete(
        ResolvedDesktopVideo(
          url,
          {
            'User-Agent': _agent,
            if (page != null &&
                referer != null &&
                (referer.toString() == '${page.origin}/' ||
                    referer.toString() == page.removeFragment().toString()))
              'Referer': referer.toString(),
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
          mimeType: hls ? 'application/vnd.apple.mpegurl' : null,
          omitCookies: message['omitCookies'] == true,
        ),
      );
    } catch (error) {
      if (error is PlatformException && error.code == 'browser_unavailable') {
        _fail(error);
      } else {
        _fail(StateError('无法读取网页会话，请关闭后重试'));
      }
    } finally {
      _capturing = false;
    }
  }

  static const _script = r'''
(() => {
  if (window.__triomiMedia) return;
  window.__triomiMedia = true;
  const hls = 'application/vnd.apple.mpegurl';
  const isHls = type => /^(application|audio)\/(vnd\.apple\.mpegurl|x-mpegurl|mpegurl)(?:;|$)/i.test(type || '');
  if (window === window.top) window.addEventListener('message', e => {
    if (e.source === window || !/^https?:\/\//.test(e.origin) ||
        !e.data || e.data.type !== 'triomi-frame-media') return;
    window.chrome.webview.postMessage({...e.data,type:'triomi-media'});
  });
  const reported = new Map();
  const report = (input, evidence = '', mimeType = '', omitCookies = false) => {
    try {
      if (typeof input !== 'string' || !input.trim()) return;
      const u = new URL(input, location.href);
      if (!/^https?:$/.test(u.protocol) ||
          (reported.has(u.href) && (!mimeType || reported.get(u.href))) ||
          (mimeType !== hls && evidence !== 'video' && !/\.(m3u8|mp4|m4v)$/i.test(u.pathname))) return;
      // Document.referrerPolicy is not exposed by all Chromium documents.
      // Read the active meta policy instead of silently inventing a Referer.
      const meta = [...document.querySelectorAll('meta[name="referrer" i]')].at(-1);
      const policy = document.referrerPolicy || meta?.content?.trim().toLowerCase() || 'strict-origin-when-cross-origin';
      const same = u.origin === location.origin;
      const downgrade = location.protocol === 'https:' && u.protocol === 'http:';
      let ref = '';
      if (policy === 'unsafe-url' || (same && policy !== 'no-referrer')) ref = location.href.split('#')[0];
      else if (policy === 'origin' || policy === 'origin-when-cross-origin' ||
        (!downgrade && policy === 'strict-origin') || (!downgrade && policy === 'strict-origin-when-cross-origin')) ref = location.origin + '/';
      reported.set(u.href, mimeType);
      const media = {url:u.href,referer:ref,page:location.href,evidence,mimeType,omitCookies};
      if (window === window.top) window.chrome.webview.postMessage({...media,type:'triomi-media'});
      else window.top.postMessage({...media,type:'triomi-frame-media'},'*');
    } catch (_) {}
  };
  const responseRequests = new WeakMap();
  const clone = Response.prototype.clone;
  Response.prototype.clone = function() {
    const response = clone.call(this), metadata = responseRequests.get(this);
    if (metadata) responseRequests.set(response, metadata);
    return response;
  };
  const text = Response.prototype.text;
  Response.prototype.text = function() {
    const url = this.url, metadata = responseRequests.get(this) || {};
    return text.call(this).then(body => {
      if (body.trim().startsWith('#EXTM3U')) report(url, 'manifest', hls, metadata.omit);
      return body;
    });
  };
  const nativeFetch = window.fetch;
  window.fetch = function(input, init) {
    const request = input instanceof Request ? input.url : String(input);
    const credentials = init && init.credentials || (input instanceof Request ? input.credentials : 'same-origin');
    let omit = credentials === 'omit';
    try { omit = omit || credentials === 'same-origin' && new URL(request, location.href).origin !== location.origin; } catch (_) {}
    return nativeFetch.apply(this, arguments).then(r => {
      const url = r.url || request;
      try { omit = omit || credentials === 'same-origin' && new URL(url, location.href).origin !== location.origin; } catch (_) {}
      responseRequests.set(r, {omit});
      if (isHls(r.headers.get('content-type'))) report(url, 'mime', hls, omit);
      else {
        report(url, '', '', omit);
        if (r.body && r.type !== 'opaque') {
          try {
            const reader = r.clone().body.getReader();
            const timer = setTimeout(() => { reader.cancel().catch(() => {}); }, 5000);
            const decoder = new TextDecoder();
            let prefix = '', bytes = 0;
            const read = () => reader.read().then(part => {
              if (part.value) {
                bytes += part.value.byteLength;
                prefix += decoder.decode(part.value.subarray(0, Math.max(0, 512 - prefix.length)), {stream:true});
              }
              const trimmed = prefix.trimStart();
              if (trimmed.startsWith('#EXTM3U')) {
                clearTimeout(timer);
                reader.cancel().catch(() => {});
                report(url, 'manifest', hls, omit);
              } else if (part.done || bytes >= 512 || trimmed.length >= 7) {
                clearTimeout(timer);
                reader.cancel().catch(() => {});
              } else return read();
            }).catch(() => { clearTimeout(timer); });
            read();
          } catch (_) {}
        }
      }
      return r;
    });
  };
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, input) {
    const request = new URL(input, location.href);
    this.addEventListener('load', () => {
      try {
        const url = this.responseURL || request.href;
        const omit = !this.withCredentials && (request.origin !== location.origin || new URL(url).origin !== location.origin);
        if (isHls(this.getResponseHeader('content-type')) ||
            ((!this.responseType || this.responseType === 'text') && this.responseText.trim().startsWith('#EXTM3U')) ||
            (this.responseType === 'arraybuffer' && this.response instanceof ArrayBuffer &&
              new TextDecoder().decode(new Uint8Array(this.response, 0, Math.min(512, this.response.byteLength))).trim().startsWith('#EXTM3U'))) {
          report(url, 'manifest', hls, omit);
        } else if (this.responseType === 'blob' && this.response instanceof Blob) {
          this.response.slice(0,512).text().then(t => {
            if (t.trim().startsWith('#EXTM3U')) report(url, 'manifest', hls, omit);
          }).catch(() => {});
        } else report(url, '', '', omit);
      } catch (_) {}
    }, {once:true});
    return open.apply(this, arguments);
  };
  const scan = () => {
    document.querySelectorAll('video,video source').forEach(v =>
      report(v.currentSrc || v.src, 'video', isHls(v.type) ? hls : ''));
    if (window.__triomiLegacyParser) document.querySelectorAll('iframe[src]').forEach(frame => {
      try {
        const url = new URL(frame.src, location.href);
        for (const value of url.searchParams.values()) report(value);
      } catch (_) {}
    });
  };
  new MutationObserver(scan).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scan, {once:true});
  else scan();
  setInterval(scan, 500);
})();
''';
}
