import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

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

/// Resolves the ordinary site in a private viewport behind the player.
/// TLS, origin, cookies and cancellation stay enforced without a modal step.
Future<ResolvedDesktopVideo> resolveWindowsVideo(
  BuildContext context,
  PlaySource line, {
  VideoResolveCancellation? cancellation,
}) async {
  final owner = cancellation ?? VideoResolveCancellation();
  if (!context.mounted || owner.isCancelled) {
    throw VideoResolveCancelled(owner.reason);
  }
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle == AppLifecycleState.hidden ||
      lifecycle == AppLifecycleState.paused ||
      lifecycle == AppLifecycleState.detached) {
    throw VideoResolveCancelled('请显示应用窗口后继续网页解析');
  }
  final overlay = Overlay.of(context, rootOverlay: true);
  final result = Completer<ResolvedDesktopVideo>();
  final closed = Completer<void>();
  var created = false;
  final entry = OverlayEntry(
    builder: (_) {
      created = true;
      return Positioned.fill(
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: Opacity(
              opacity: 0,
              child: _DesktopVideoProbe(
                line: line,
                owner: owner,
                closed: closed,
                onResolved: (value) {
                  if (!result.isCompleted) result.complete(value);
                },
                onError: (message) {
                  if (!result.isCompleted) {
                    result.completeError(StateError(message));
                  }
                },
              ),
            ),
          ),
        ),
      );
    },
  );
  void cancel() {
    if (!result.isCompleted) {
      result.completeError(VideoResolveCancelled(owner.reason));
    }
  }

  owner.addListener(cancel);
  overlay.insert(entry);
  try {
    return await result.future;
  } finally {
    owner.removeListener(cancel);
    entry.remove();
    entry.dispose();
    if (!created && !closed.isCompleted) closed.complete();
    await closed.future;
    if (cancellation == null) owner.dispose();
  }
}

class _DesktopVideoProbe extends StatefulWidget {
  const _DesktopVideoProbe({
    required this.line,
    required this.owner,
    required this.closed,
    required this.onResolved,
    required this.onError,
  });
  final PlaySource line;
  final VideoResolveCancellation owner;
  final Completer<void> closed;
  final ValueChanged<ResolvedDesktopVideo> onResolved;
  final ValueChanged<String> onError;

  @override
  State<_DesktopVideoProbe> createState() => _DesktopVideoProbeState();
}

class _DesktopVideoProbeState extends State<_DesktopVideoProbe>
    with WidgetsBindingObserver {
  static Future<void>? _environment;
  static bool _environmentReady = false;
  final _web = WebviewController();
  StreamSubscription<dynamic>? _messages;
  StreamSubscription<WebErrorStatus>? _errors;
  StreamSubscription<String>? _urls;
  Uri? _documentUrl;
  Uri? _parentDocument;
  Uri? _parent;
  bool _enteredPlayer = false;
  Timer? _deadline;
  bool _ready = false;
  bool _initialized = false;
  Future<void>? _closingWeb;
  bool _finished = false;
  String? _error;
  Future<void>? _creating;
  Future<void>? _initializing;
  bool _capturing = false;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.owner.addListener(_cancelBrowser);
    _deadline = Timer(const Duration(seconds: 45), () {
      _fail('播放页未返回可播放地址，请重试或换来源');
    });
    _initializing = _initialize();
    unawaited(_initializing);
  }

  void _cancelBrowser() {
    _finished = true;
    _deadline?.cancel();
    // Backgrounding may suppress frames: close the native surface now.
    unawaited(() async {
      if (_creating != null) await _initializing;
      await _disposeWeb();
    }());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop inactive means visible but unfocused, not a hidden application.
    // WebView2 focus changes and normal multitasking must not cancel the page.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.owner.cancel('应用窗口已隐藏，请显示窗口后继续网页解析');
    }
  }

  Future<void> _initialize() async {
    try {
      if (_httpUri(widget.line.url) == null) {
        throw StateError('播放页必须是 HTTP(S) 地址');
      }
      final headers = {
        for (final e in widget.line.headers.entries)
          e.key.toLowerCase(): e.value,
      };
      if (headers.keys.any((k) => k != 'user-agent' && k != 'referer')) {
        throw StateError('此来源需要桌面暂不支持的专用请求头，请更换来源');
      }
      if (await WebviewController.getWebViewVersion() == null) {
        throw StateError('请安装 Microsoft Edge WebView2 Runtime 后重试');
      }
      if (!mounted || _finished || _error != null) return;
      if (!_environmentReady) {
        _environment ??= _initializeEnvironment();
        await _environment;
        _environment = null;
      }
      if (!mounted || _finished || _error != null) return;
      _creating = _web.initialize();
      await _creating;
      _initialized = true;
      if (!mounted || _finished || _error != null) {
        await _disposeWeb();
        return;
      }
      await _web.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      if (!mounted || _finished) return;
      _agent = headers['user-agent'] ?? _defaultAgent;
      if (_agent.isEmpty || _agent.contains(RegExp(r'[\r\n]'))) {
        throw StateError('来源 User-Agent 无效，请更换来源');
      }
      await _web.setUserAgent(_agent);
      if (!mounted || _finished) return;
      _messages = _web.webMessage.listen(_onMessage);
      _urls = _web.url.listen((value) => _documentUrl = _httpUri(value));
      _errors = _web.onLoadError.listen((status) {
        // Following the parent link deliberately cancels its remaining load.
        // Certificate, connection and destination failures still fail normally.
        if (_enteredPlayer &&
            (status == WebErrorStatus.WebErrorStatusOperationCanceled ||
                (status == WebErrorStatus.WebErrorStatusConnectionAborted &&
                    _documentUrl == _parentDocument))) {
          return;
        }
        _fail('播放页加载失败，请重试或换来源');
      });
      await _web.addScriptToExecuteOnDocumentCreated(
        'window.__triomiLegacyParser = ${widget.line.useLegacyParser};\n$_script',
      );
      if (!mounted || _finished || _error != null) {
        await _disposeWeb();
        return;
      }
      setState(() => _ready = true);
      // The plugin cannot set arbitrary headers. Navigate through a link in
      // the real parent document so its normal referrer policy applies.
      _parent = _httpUri(headers['referer']);
      if (_parent == _httpUri(widget.line.url)) _parent = null;
      await _web.loadUrl((_parent ?? _httpUri(widget.line.url)!).toString());
    } catch (error) {
      _fail(
        error is StateError ? error.message.toString() : '网页播放组件暂不可用，请重试或更换来源',
      );
    }
  }

  static Future<void> _initializeEnvironment() async {
    try {
      final support = await getApplicationSupportDirectory();
      await WebviewController.initializeEnvironment(
        userDataPath: '${support.path}/video-webview',
      );
      // Keep completed state, not a Future bound to its caller's async zone.
      _environmentReady = true;
    } catch (_) {
      _environment = null;
      rethrow;
    }
  }

  void _enterPlayer() {
    if (_enteredPlayer || _parent == null || !mounted || _finished) return;
    _enteredPlayer = true;
    unawaited(
      _web
          .executeScript(
            '(() => { const a = document.createElement("a"); '
            'a.href = ${jsonEncode(widget.line.url)}; '
            'a.target = "_self"; document.body.appendChild(a); a.click(); })();',
          )
          .catchError((Object _) {
            _fail('播放页导航失败，请重试或换来源');
            return null;
          }),
    );
  }

  Future<void> _onMessage(dynamic message) async {
    if (!mounted || _finished || _capturing || _error != null) return;
    if (message is String) {
      try {
        message = jsonDecode(message);
      } catch (_) {
        return;
      }
    }
    if (message is! Map) return;
    if (message['type'] == 'triomi-parent-ready') {
      final page = _httpUri(message['page']?.toString());
      // Compare against the native top-level URL to allow real redirects,
      // never a frame's claimed parent or a downgrade of the HTTPS parent.
      if (_parent != null &&
          page != null &&
          (_parent!.scheme != 'https' || page.scheme == 'https') &&
          (page.removeFragment() == _parent?.removeFragment() ||
              page.removeFragment() == _documentUrl?.removeFragment())) {
        _parentDocument = page.removeFragment();
        _enterPlayer();
      }
      return;
    }
    if (message['type'] != 'triomi-media') return;
    final uri = _httpUri(message['url']?.toString());
    if (_httpUri(widget.line.url)?.scheme == 'https' &&
        uri?.scheme != 'https') {
      return;
    }
    final hls = message['mimeType'] == 'application/vnd.apple.mpegurl';
    // An extensionless URL requires observed media evidence, never a plain link.
    if (uri == null ||
        (!hls &&
            message['evidence'] != 'video' &&
            !RegExp(
              r'\.(m3u8|mp4|m4v)$',
              caseSensitive: false,
            ).hasMatch(uri.path))) {
      return;
    }
    final url = uri.toString();
    if (widget.line.unavailableVideoUrls.contains(url)) {
      _fail('此线路返回了站点的加载失败占位，请更换播放列表');
      return;
    }
    if (const [
      'googleads',
      'googlesyndication',
      'adposter',
    ].any(url.contains)) {
      return;
    }
    // Only the configured browser UA and exact-target native CookieManager
    // output may become request headers. Never accept page-supplied credentials.
    final page = _httpUri(message['page']?.toString());
    final referer = _httpUri(message['referer']?.toString());
    _capturing = true;
    try {
      final cookie = message['omitCookies'] == true
          ? null
          : await WindowsSourceSession.videoCookies(url);
      if (!mounted || _finished || _error != null || widget.owner.isCancelled) {
        return;
      }
      _finished = true;
      _deadline?.cancel();
      widget.onResolved(
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
    } catch (_) {
      _fail('无法读取网页会话，请关闭后重试');
    } finally {
      _capturing = false;
    }
  }

  void _fail(String message) {
    if (!mounted || _finished || _error != null) return;
    _deadline?.cancel();
    _finished = true;
    if (_ready) unawaited(_web.stop().catchError((Object _) {}));
    setState(() => _error = message);
    widget.onError(message);
  }

  Future<void> _disposeWeb() {
    if (!_initialized) return Future<void>.value();
    return _closingWeb ??= () async {
      try {
        await _web.dispose();
      } catch (_) {
        // Never log request/session data while closing a failed browser.
      }
    }();
  }

  @override
  void dispose() {
    if (!_finished) widget.owner.cancel('播放页面已关闭');
    _finished = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.owner.removeListener(_cancelBrowser);
    _deadline?.cancel();
    unawaited(_messages?.cancel());
    unawaited(_errors?.cancel());
    unawaited(_urls?.cancel());
    unawaited(() async {
      try {
        if (_creating != null) await _initializing;
        await _disposeWeb();
      } finally {
        if (!widget.closed.isCompleted) widget.closed.complete();
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready
      ? Webview(
          _web,
          permissionRequested: (_, _, _) async =>
              WebviewPermissionDecision.deny,
        )
      : const SizedBox.expand();

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
      const policy = document.referrerPolicy || 'strict-origin-when-cross-origin';
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
  const ready = () => {
    if (window === window.top) window.chrome.webview.postMessage({type:'triomi-parent-ready',page:location.href});
    scan();
  };
  new MutationObserver(scan).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, {once:true});
  else ready();
  setInterval(scan, 500);
})();
''';
}
