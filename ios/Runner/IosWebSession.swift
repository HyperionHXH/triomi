import Flutter
import UIKit
import WebKit

/// App-only WK cookie storage. Rule logins persist only through the explicit
/// browser Save action. Playback uses a separate in-memory store, not that jar.
final class IosWebSession {
  let ruleStore: WKWebsiteDataStore
  let videoStore: WKWebsiteDataStore
  private var browser: IosRuleBrowser?
  private var playback: IosVideoResolver?
  private var download: IosVideoResolver?

  init(ruleStore: WKWebsiteDataStore = .default(), videoStore: WKWebsiteDataStore = .nonPersistent()) {
    self.ruleStore = ruleStore
    self.videoStore = videoStore
  }

  static func webURL(_ value: String, httpsOnly: Bool = false) -> URL? {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
          httpsOnly ? scheme == "https" : ["http", "https"].contains(scheme),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
  }

  /// Clear only disposable HTTP responses. Source logins and DOM storage stay.
  func clearHttpCache(completion: @escaping () -> Void) {
    let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
    let group = DispatchGroup()
    for store in [ruleStore, videoStore] {
      group.enter()
      store.removeData(ofTypes: types, modifiedSince: .distantPast) { group.leave() }
    }
    if let browser = browser {
      group.enter(); browser.clearHttpCache { group.leave() }
    }
    for resolver in [playback, download].compactMap({ $0 }) {
      group.enter(); resolver.clearHttpCache { group.leave() }
    }
    group.notify(queue: .main, execute: completion)
  }

  func handle(_ call: FlutterMethodCall, presenter: UIViewController?, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "cancelVideoResolve" {
      playback?.cancel(requestId: args["requestId"] as? String); result(nil); return
    }
    if call.method == "cancelDownloadVideoResolve" {
      download?.cancel(requestId: args["requestId"] as? String); result(nil); return
    }
    let ruleMethod = call.method.hasPrefix("rule")
    guard let value = args["url"] as? String, let url = Self.webURL(value, httpsOnly: ruleMethod) else {
      result(FlutterError(code: "invalid_url", message: ruleMethod ? "Source sessions require HTTPS" : "A public HTTP(S) URL is required", details: nil)); return
    }
    switch call.method {
    case "ruleCookieHeader", "videoCookieHeader":
      Self.cookieHeader(url: url, store: ruleMethod ? ruleStore : videoStore) { result($0) }
    case "ruleStoreCookies":
      Self.storeCookies(args["cookies"] as? [String] ?? [], url: url, store: ruleStore) { result(true) }
    case "ruleOpenSession":
      guard browser == nil else {
        result(FlutterError(code: "session_busy", message: "A source browser is already open", details: nil)); return
      }
      guard let presenter = presenter, UIApplication.shared.applicationState == .active else {
        result(FlutterError(code: "activity_inactive", message: "Return to the app before opening a source browser", details: nil)); return
      }
      let view = IosRuleBrowser(url: url, userAgent: args["userAgent"] as? String, persistentStore: ruleStore) { [weak self] saved in
        self?.browser = nil
        result(["ok": true, "saved": saved])
      }
      browser = view
      let navigation = UINavigationController(rootViewController: view)
      navigation.isModalInPresentation = true
      presenter.present(navigation, animated: true)
    case "resolveVideo", "resolveDownloadVideo":
      guard UIApplication.shared.applicationState == .active else {
        result(FlutterError(code: "activity_inactive", message: "Return to the app to resolve the playback page", details: nil)); return
      }
      let resolver = IosVideoResolver(store: args["omitCookies"] as? Bool == true ? .nonPersistent() : videoStore)
      if call.method == "resolveVideo" { playback?.cancel(); playback = resolver }
      else { download?.cancel(); download = resolver }
      resolver.resolve(url: url, args: args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func cookieDomainMatches(_ cookie: HTTPCookie, url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let domain = cookie.domain.lowercased()
    return domain.hasPrefix(".")
      ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
      : host == domain
  }

  static func cookieApplies(_ cookie: HTTPCookie, to url: URL) -> Bool {
    guard cookieDomainMatches(cookie, url: url),
          cookie.expiresDate.map({ $0 > Date() }) ?? true,
          !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
    let path = url.path.isEmpty ? "/" : url.path
    let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
    return path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
  }

  static func cookieHeader(url: URL, store: WKWebsiteDataStore, completion: @escaping (String?) -> Void) {
    store.httpCookieStore.getAllCookies { cookies in
      let matching = cookies.filter { cookieApplies($0, to: url) }.sorted { $0.path.count > $1.path.count }
      let value = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      completion(value.isEmpty ? nil : value)
    }
  }

  static func storeCookies(_ values: [String], url: URL, store: WKWebsiteDataStore, completion: @escaping () -> Void) {
    let group = DispatchGroup()
    for value in values {
      for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url) {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = url.host?.lowercased() ?? ""
        guard host == domain || host.hasSuffix("." + domain) else { continue }
        if cookie.name.hasPrefix("__Secure-") && !cookie.isSecure { continue }
        if cookie.name.hasPrefix("__Host-") && (!cookie.isSecure || cookie.path != "/" || value.range(of: #"(?:^|;)\s*domain\s*="# , options: [.regularExpression, .caseInsensitive]) != nil) { continue }
        group.enter()
        store.httpCookieStore.setCookie(cookie) { group.leave() }
      }
    }
    group.notify(queue: .main, execute: completion)
  }
}

private final class IosRuleBrowser: UIViewController, WKNavigationDelegate, WKUIDelegate {
  private let url: URL
  private let userAgent: String?
  private let persistentStore: WKWebsiteDataStore
  private let sessionStore = WKWebsiteDataStore.nonPersistent()
  private var web: WKWebView!
  private var complete: ((Bool) -> Void)?

  init(url: URL, userAgent: String?, persistentStore: WKWebsiteDataStore, completion: @escaping (Bool) -> Void) {
    self.url = url; self.userAgent = userAgent; self.persistentStore = persistentStore; self.complete = completion
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = url.host
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存会话", style: .done, target: self, action: #selector(save))
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = sessionStore
    web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = self
    web.uiDelegate = self
    if let userAgent = userAgent, !userAgent.isEmpty { web.customUserAgent = userAgent }
    view = web
    persistentStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self = self, self.complete != nil else { return }
      let group = DispatchGroup()
      for cookie in cookies where IosWebSession.cookieDomainMatches(cookie, url: self.url) {
        group.enter(); self.sessionStore.httpCookieStore.setCookie(cookie) { group.leave() }
      }
      group.notify(queue: .main) { [weak self] in
        guard let self = self, self.complete != nil else { return }
        self.web.load(URLRequest(url: self.url))
      }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    // Manual verification may follow normal HTTPS account redirects. Never
    // navigate into file/custom schemes or accept a TLS exception.
    let allowed = navigationAction.request.url.flatMap { IosWebSession.webURL($0.absoluteString, httpsOnly: true) } != nil
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    decisionHandler(.deny)
  }

  func clearHttpCache(completion: @escaping () -> Void) {
    sessionStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                            modifiedSince: .distantPast, completionHandler: completion)
  }

  @objc private func cancel() { finish(false) }

  @objc private func save() {
    navigationItem.rightBarButtonItem?.isEnabled = false
    sessionStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self = self, self.complete != nil else { return }
      // The browser may visit an identity provider. Only the requested source's
      // applicable cookies cross into the persistent source-session store.
      self.persistentStore.httpCookieStore.getAllCookies { existing in
        let group = DispatchGroup()
        for cookie in existing where IosWebSession.cookieDomainMatches(cookie, url: self.url) {
          group.enter(); self.persistentStore.httpCookieStore.delete(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
          let writes = DispatchGroup()
          for cookie in cookies where IosWebSession.cookieDomainMatches(cookie, url: self.url) {
            writes.enter(); self.persistentStore.httpCookieStore.setCookie(cookie) { writes.leave() }
          }
          writes.notify(queue: .main) { self.finish(true) }
        }
      }
    }
  }

  private func finish(_ saved: Bool) {
    guard let callback = complete else { return }
    complete = nil; web?.stopLoading(); web?.navigationDelegate = nil
    dismiss(animated: true) { callback(saved) }
  }
}

/// Runs the site's ordinary WebKit player. No custom certificate handling,
/// authentication bypass, DRM extraction, or non-HTTP resource access.
final class IosVideoResolver: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
  private let store: WKWebsiteDataStore
  private var web: WKWebView?
  private var pending: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var initialURL: URL?
  private var requestId: String?
  private var forwardedHeaders = Set<String>()
  private var inputHeaders = [String: String]()
  private var unavailable = Set<String>()
  private var userAgent = ""
  private var completing = false
  private var omitInputCookies = false

  init(store: WKWebsiteDataStore) { self.store = store }

  func clearHttpCache(completion: @escaping () -> Void) {
    store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                     modifiedSince: .distantPast, completionHandler: completion)
  }

  func resolve(url: URL, args: [String: Any], result: @escaping FlutterResult) {
    pending = result; requestId = args["requestId"] as? String
    initialURL = url
    omitInputCookies = args["omitCookies"] as? Bool == true
    unavailable = Set(args["unavailableVideoUrls"] as? [String] ?? [])
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.userContentController.add(self, name: "triomiMedia")
    configuration.userContentController.addUserScript(WKUserScript(source: Self.detectionScript(useLegacyParser: args["useLegacyParser"] as? Bool == true), injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    view.navigationDelegate = self
    view.uiDelegate = self
    view.isUserInteractionEnabled = false
    view.alpha = 0.01
    IosPlatformBridge.presenter()?.view.insertSubview(view, at: 0)
    let headers = args["headers"] as? [String: String] ?? [:]
    inputHeaders = headers
    forwardedHeaders = Set(headers.keys.map { $0.lowercased() }).subtracting(["cookie", "host", "content-length", "user-agent"])
    if let agent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value { view.customUserAgent = agent }
    web = view
    let deadline = DispatchWorkItem { [weak self] in self?.fail("resolve_timeout", "The playback page did not return a playable HTTP(S) video") }
    timeout = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: deadline)
    view.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
      guard let self = self, self.pending != nil else { return }
      self.userAgent = view.customUserAgent ?? (value as? String ?? "")
      var request = URLRequest(url: url)
      for (name, value) in headers where !["cookie", "host", "content-length"].contains(name.lowercased()) {
        request.setValue(value, forHTTPHeaderField: name)
      }
      // A caller-provided Cookie is scoped only to its exact input host. It is
      // never reapplied to redirected pages or guessed media/CDN hosts.
      if !self.omitInputCookies, let header = headers.first(where: { $0.key.lowercased() == "cookie" })?.value {
        let group = DispatchGroup()
        for pair in header.split(separator: ";") {
          let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          guard parts.count == 2, let host = url.host,
                let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: parts[0].trimmingCharacters(in: .whitespaces),
                                                     .value: String(parts[1]), .secure: url.scheme == "https" ? "TRUE" : "FALSE"]) else { continue }
          group.enter(); self.store.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in if self?.pending != nil { view.load(request) } }
      } else { view.load(request) }
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    receiveMedia(message.body as? [String: Any] ?? [:])
  }

  func receiveMedia(_ payload: [String: Any]) {
    guard let value = payload["url"] as? String,
          let url = IosWebSession.webURL(value) else { return }
    let mimeType = payload["mimeType"] as? String == "application/vnd.apple.mpegurl" ? "application/vnd.apple.mpegurl" : nil
    guard Self.mediaURL(url) || mimeType != nil || payload["evidence"] as? String == "video" else { return }
    found(url, page: (payload["page"] as? String).flatMap { IosWebSession.webURL($0) },
          policy: payload["policy"] as? String ?? "strict-origin-when-cross-origin",
          mimeType: mimeType, omitCookies: payload["omitCookies"] as? Bool == true)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, IosWebSession.webURL(url.absoluteString) != nil else {
      decisionHandler(.cancel); return
    }
    if Self.mediaURL(url) {
      // A suffixed HLS navigation carries the same format hint as a sniffed one.
      found(url, page: navigationAction.sourceFrame.request.url, policy: "strict-origin-when-cross-origin",
            mimeType: url.pathExtension.lowercased() == "m3u8" ? "application/vnd.apple.mpegurl" : nil)
      decisionHandler(.cancel); return
    }
    // WebKit owns navigation cookie scoping and default TLS validation. Strip
    // explicit caller credentials if a redirect tries to carry them elsewhere.
    if let initial = initialURL, !Self.sameOrigin(initial, url),
       (navigationAction.request.allHTTPHeaderFields ?? [:]).keys.contains(where: { forwardedHeaders.contains($0.lowercased()) }) {
      var request = navigationAction.request
      request.allHTTPHeaderFields = (request.allHTTPHeaderFields ?? [:]).filter { !forwardedHeaders.contains($0.key.lowercased()) }
      decisionHandler(.cancel); webView.load(request); return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    let type = navigationResponse.response.mimeType?.lowercased() ?? ""
    if ["application/vnd.apple.mpegurl", "application/x-mpegurl", "application/mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(type),
       let url = navigationResponse.response.url, IosWebSession.webURL(url.absoluteString) != nil {
      found(url, page: webView.url ?? initialURL, policy: "strict-origin-when-cross-origin", mimeType: "application/vnd.apple.mpegurl")
      decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code != NSURLErrorCancelled { fail("resolve_failed", "The playback page could not be loaded") }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("resolve_failed", "The playback page process terminated") }

  private func found(_ url: URL, page: URL?, policy: String, mimeType: String? = nil, omitCookies: Bool = false) {
    guard pending != nil, !completing else { return }
    if unavailable.contains(url.absoluteString) { fail("source_unavailable", "This route returned the source's unavailable-video placeholder"); return }
    guard !["googleads", "googlesyndication", "adposter"].contains(where: { url.absoluteString.contains($0) }) else { return }
    completing = true
    let omit = omitInputCookies || omitCookies
    let complete: (String?) -> Void = { [weak self] cookies in
      guard let self = self, let callback = self.pending else { return }
      var headers = [String: String]()
      if let initial = self.initialURL, Self.sameOrigin(initial, url) {
        let excluded = ["cookie", "host", "content-length", "referer", "user-agent",
                        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                        "te", "trailer", "transfer-encoding", "upgrade"]
        for (name, value) in self.inputHeaders where !excluded.contains(name.lowercased()) {
          headers[name] = value
        }
      }
      if !self.userAgent.isEmpty { headers["User-Agent"] = self.userAgent }
      if let cookies = cookies { headers["Cookie"] = cookies }
      if let page = page, let referer = Self.referrer(page: page, target: url, policy: policy) { headers["Referer"] = referer }
      self.pending = nil; self.cleanup()
      var response: [String: Any] = ["url": url.absoluteString, "headers": headers]
      if let mimeType = mimeType { response["mimeType"] = mimeType }
      if omit { response["omitCookies"] = true }
      callback(response)
    }
    if omit { complete(nil) }
    else { IosWebSession.cookieHeader(url: url, store: store, completion: complete) }
  }

  static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() &&
      (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
  }

  static func referrer(page: URL, target: URL, policy: String) -> String? {
    let same = sameOrigin(page, target)
    let downgrade = page.scheme == "https" && target.scheme == "http"
    var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
    components?.fragment = nil; components?.user = nil; components?.password = nil
    let full = components?.url?.absoluteString
    components?.path = "/"; components?.query = nil
    let origin = components?.url?.absoluteString
    switch policy.lowercased() {
    case "no-referrer": return nil
    case "same-origin": return same ? full : nil
    case "origin": return origin
    case "strict-origin": return downgrade ? nil : origin
    case "origin-when-cross-origin": return same ? full : origin
    case "unsafe-url": return full
    case "no-referrer-when-downgrade": return downgrade ? nil : full
    default: return downgrade ? nil : (same ? full : origin)
    }
  }

  static func mediaURL(_ url: URL) -> Bool { ["m3u8", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }

  func cancel(requestId: String? = nil) {
    if requestId == nil || requestId == self.requestId { fail("resolve_cancelled", "Video resolution cancelled") }
  }

  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    decisionHandler(.deny)
  }

  private func fail(_ code: String, _ message: String) {
    guard let callback = pending else { return }
    pending = nil; cleanup(); callback(FlutterError(code: code, message: message, details: nil))
  }

  private func cleanup() {
    timeout?.cancel(); timeout = nil
    web?.stopLoading(); web?.navigationDelegate = nil
    web?.uiDelegate = nil
    web?.configuration.userContentController.removeScriptMessageHandler(forName: "triomiMedia")
    web?.configuration.userContentController.removeAllUserScripts()
    web?.removeFromSuperview()
    web = nil; requestId = nil
  }

  static func detectionScript(useLegacyParser: Bool) -> String {
    script.replacingOccurrences(of: "__TRIOMI_LEGACY__", with: useLegacyParser ? "true" : "false")
  }

  private static let script = #"""
    (() => {
      if (window.__triomiMedia) return; window.__triomiMedia = true;
      const legacy = __TRIOMI_LEGACY__;
      const hls = 'application/vnd.apple.mpegurl';
      const isHls = type => /^(application|audio)\/(vnd\.apple\.mpegurl|x-mpegurl|mpegurl)(?:;|$)/i.test(type || '');
      const reported = new Map();
      const report = (input, evidence = '', mimeType = '', omitCookies = false) => {
        try {
          if (typeof input !== 'string' || !input.trim()) return;
          const url = new URL(input, location.href);
          if (!/^https?:$/.test(url.protocol) || url.username || url.password ||
              (reported.has(url.href) && (!mimeType || reported.get(url.href))) ||
              (mimeType !== hls && evidence !== 'video' && !/\.(m3u8|mp4|m4v)$/i.test(url.pathname))) return;
          reported.set(url.href, mimeType);
          window.webkit.messageHandlers.triomiMedia.postMessage({url:url.href, page:location.href,
            policy:document.referrerPolicy || 'strict-origin-when-cross-origin', evidence, mimeType, omitCookies});
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
        return nativeFetch.apply(this, arguments).then(response => {
          const url = response.url || request;
          try { omit = omit || credentials === 'same-origin' && new URL(url, location.href).origin !== location.origin; } catch (_) {}
          responseRequests.set(response, {omit});
          if (isHls(response.headers.get('content-type'))) report(url, 'mime', hls, omit);
          else {
            report(url, '', '', omit);
            if (response.body && response.type !== 'opaque') {
              try {
                const reader = response.clone().body.getReader();
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
                    clearTimeout(timer); reader.cancel().catch(() => {});
                    report(url, 'manifest', hls, omit);
                  } else if (part.done || bytes >= 512 || trimmed.length >= 7) {
                    clearTimeout(timer); reader.cancel().catch(() => {});
                  } else return read();
                }).catch(() => { clearTimeout(timer); });
                read();
              } catch (_) {}
            }
          }
          return response;
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
              this.response.slice(0,512).text().then(body => {
                if (body.trim().startsWith('#EXTM3U')) report(url, 'manifest', hls, omit);
              }).catch(() => {});
            } else report(url, '', '', omit);
          } catch (_) {}
        }, {once:true});
        return open.apply(this, arguments);
      };
      const scan = () => {
        document.querySelectorAll('video,video source').forEach(v => {
          report(v.currentSrc || v.src, 'video', isHls(v.type) ? hls : '');
          if (v.tagName === 'VIDEO') { v.muted = true; const p = v.play(); if (p) p.catch(() => {}); }
        });
        if (legacy) document.querySelectorAll('iframe[src]').forEach(frame => {
          try {
            const url = new URL(frame.src, location.href);
            for (const value of url.searchParams.values()) report(value);
          } catch (_) {}
        });
      };
      new MutationObserver(scan).observe(document, {childList:true, subtree:true, attributes:true, attributeFilter:['src','type']});
      setInterval(scan, 500);
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scan, {once:true});
      else scan();
    })();
    """#
}
