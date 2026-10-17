import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../core/models/chapter.dart';
import '../../core/models/video_resolve_cancellation.dart';
import '../../core/source/windows_source_session.dart';

class ResolvedDesktopVideo {
  const ResolvedDesktopVideo(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

/// The ordinary site/player runtime is visible and cancellable. Browser TLS,
/// origin and authentication policies remain in force; no clearance solving.
Future<ResolvedDesktopVideo> resolveWindowsVideo(
  BuildContext context,
  PlaySource line, {
  VideoResolveCancellation? cancellation,
  String purpose = '播放',
}) async {
  final owner = cancellation ?? VideoResolveCancellation();
  if (!context.mounted || owner.isCancelled) {
    throw VideoResolveCancelled(owner.reason);
  }
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
    throw VideoResolveCancelled('请返回应用前台后继续网页解析');
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final closed = Completer<void>();
  var dialogCreated = false;
  late final DialogRoute<ResolvedDesktopVideo> route;
  void cancel() {
    scheduleMicrotask(() {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    });
  }
  route = DialogRoute<ResolvedDesktopVideo>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (_) {
      dialogCreated = true;
      return _DesktopResolveDialog(
        line: line,
        owner: owner,
        purpose: purpose,
        onResolved: (result) {
          if (route.isActive) navigator.removeRoute(route, result);
        },
        closed: closed,
      );
    },
  );
  owner.addListener(cancel);
  try {
    final result = await navigator.push(route);
    await route.completed;
    if (!dialogCreated && !closed.isCompleted) closed.complete();
    await closed.future;
    if (result == null || owner.isCancelled) {
      throw VideoResolveCancelled(owner.reason);
    }
    return result;
  } finally {
    owner.removeListener(cancel);
    if (cancellation == null) owner.dispose();
  }
}

class _DesktopResolveDialog extends StatefulWidget {
  const _DesktopResolveDialog({
    required this.line,
    required this.owner,
    required this.purpose,
    required this.closed,
    required this.onResolved,
  });
  final PlaySource line;
  final VideoResolveCancellation owner;
  final String purpose;
  final Completer<void> closed;
  final ValueChanged<ResolvedDesktopVideo> onResolved;

  @override
  State<_DesktopResolveDialog> createState() => _DesktopResolveDialogState();
}

class _DesktopResolveDialogState extends State<_DesktopResolveDialog>
    with WidgetsBindingObserver {
  static Future<void>? _environment;
  static bool _environmentReady = false;
  final _web = WebviewController();
  StreamSubscription<dynamic>? _messages;
  StreamSubscription<WebErrorStatus>? _errors;
  StreamSubscription<LoadingState>? _loading;
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
    if (state != AppLifecycleState.resumed) {
      widget.owner.cancel('应用已进入后台，请返回前台后继续下载');
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
      _errors = _web.onLoadError.listen((_) {
        _fail('播放页加载失败，请重试或换来源');
      });
      await _web.addScriptToExecuteOnDocumentCreated(_script);
      if (!mounted || _finished || _error != null) {
        await _disposeWeb();
        return;
      }
      setState(() => _ready = true);
      // The plugin cannot set arbitrary headers. Navigate through a link in
      // the real parent document so its normal referrer policy applies.
      final parent = _httpUri(headers['referer']);
      if (parent != null && parent != _httpUri(widget.line.url)) {
        var navigated = false;
        _loading = _web.loadingState.listen((state) {
          if (state != LoadingState.navigationCompleted ||
              navigated ||
              !mounted ||
              _finished ||
              _error != null) {
            return;
          }
          navigated = true;
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
        });
      }
      await _web.loadUrl((parent ?? _httpUri(widget.line.url)!).toString());
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

  Future<void> _onMessage(dynamic message) async {
    if (!mounted || _finished || _capturing || _error != null) return;
    if (message is String) {
      try {
        message = jsonDecode(message);
      } catch (_) {
        return;
      }
    }
    if (message is! Map || message['type'] != 'triomi-media') return;
    final uri = _httpUri(message['url']?.toString());
    if (_httpUri(widget.line.url)?.scheme == 'https' && uri?.scheme != 'https') {
      return;
    }
    // A webpage, blob or arbitrary postMessage is never treated as a stream.
    if (uri == null ||
        !RegExp(
          r'\.(m3u8|mp4|m4v)$',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
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
      final cookie = await WindowsSourceSession.videoCookies(url);
      if (!mounted || _finished || _error != null || widget.owner.isCancelled) return;
      _finished = true;
      _deadline?.cancel();
      widget.onResolved(
        ResolvedDesktopVideo(url, {
          'User-Agent': _agent,
          if (page != null && referer != null &&
              (referer.toString() == '${page.origin}/' ||
                  referer.toString() == page.removeFragment().toString()))
            'Referer': referer.toString(),
          if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
        }),
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
    if (_ready) unawaited(_web.stop().catchError((Object _) {}));
    setState(() => _error = message);
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
    _finished = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.owner.removeListener(_cancelBrowser);
    _deadline?.cancel();
    unawaited(_messages?.cancel());
    unawaited(_errors?.cancel());
    unawaited(_loading?.cancel());
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
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 900,
      height: 600,
      child: Column(
        children: [
          ListTile(
            title: Text(_error ?? '正在为${widget.purpose}查找视频地址'),
            subtitle: Text(
              '${_httpUri(widget.line.url)?.host ?? ''} · 可手动操作网页；'
              '${widget.purpose == '下载' ? '取消将暂停下载' : '可随时取消解析'}',
            ),
            trailing: IconButton(
              tooltip: '取消解析',
              onPressed: () => widget.owner.cancel(),
              icon: const Icon(Icons.close),
            ),
          ),
          Expanded(
            child: _ready
                ? Webview(
                    _web,
                    permissionRequested: (_, _, _) async =>
                        WebviewPermissionDecision.deny,
                  )
                : Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : const Text('关闭后可以重试或更换来源'),
                  ),
          ),
        ],
      ),
    ),
  );

  static const _script = r'''
(() => {
  if (window.__triomiMedia) return;
  window.__triomiMedia = true;
  if (window === window.top) window.addEventListener('message', e => {
    if (e.source === window || !/^https?:\/\//.test(e.origin) ||
        !e.data || e.data.type !== 'triomi-frame-media') return;
    window.chrome.webview.postMessage({...e.data,type:'triomi-media'});
  });
  const report = input => {
    try {
      const u = new URL(input, location.href);
      if (!/^https?:$/.test(u.protocol) || !/\.(m3u8|mp4|m4v)$/i.test(u.pathname)) return;
      const policy = document.referrerPolicy || 'strict-origin-when-cross-origin';
      const same = u.origin === location.origin;
      const downgrade = location.protocol === 'https:' && u.protocol === 'http:';
      let ref = '';
      if (policy === 'unsafe-url' || (same && policy !== 'no-referrer')) ref = location.href.split('#')[0];
      else if (policy === 'origin' || policy === 'origin-when-cross-origin' ||
        (!downgrade && policy === 'strict-origin') || (!downgrade && policy === 'strict-origin-when-cross-origin')) ref = location.origin + '/';
      const media = {url:u.href,referer:ref,page:location.href};
      // WebView2's top-level WebMessageReceived does not receive frame events.
      // Document-start scripts run in frames too; relay only HTTP(S) origins.
      if (window === window.top) window.chrome.webview.postMessage({...media,type:'triomi-media'});
      else window.top.postMessage({...media,type:'triomi-frame-media'},'*');
    } catch (_) {}
  };
  const nativeFetch = window.fetch;
  window.fetch = function() {
    return nativeFetch.apply(this, arguments).then(r => {
      if (/\.(m3u8|mp4|m4v)(?:[?#]|$)/i.test(r.url)) report(r.url);
      return r;
    });
  };
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function() {
    this.addEventListener('load', () => report(this.responseURL));
    return open.apply(this, arguments);
  };
  const scan = () => document.querySelectorAll('video,video source').forEach(v => report(v.currentSrc || v.src));
  document.addEventListener('DOMContentLoaded', () => {
    new MutationObserver(scan).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
    scan(); setInterval(scan, 500);
  });
})();
''';
}
