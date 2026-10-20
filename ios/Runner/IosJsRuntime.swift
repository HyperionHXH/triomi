import Flutter
import WebKit

/// WebKit owns JS execution in WebContent, never the Flutter/UI thread.
/// Each session uses a nonpersistent store and a separate process pool. Public
/// WebKit APIs do not expose a PID kill or a committed-memory budget: destroying
/// a view revokes its host bridge immediately, but is not a promise of immediate
/// WebContent process termination. The OS may also terminate a process itself.
final class IosJsRuntime {
    private let channel: FlutterMethodChannel
    private var sessions: [String: IosJsSession] = [:]

    init(messenger: FlutterBinaryMessenger, channelName: String = "triomi/ios-js-runtime") {
        channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "js_session_reset", message: "JS 运行时已释放", details: nil))
                return
            }
            self.handle(call, result: result)
        }
    }

    // Internal for real WKWebView XCTest coverage; production uses the channel.
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any], let identity = args["session"] as? String else {
            result(FlutterError(code: "js_execution", message: "无效的 JS 会话", details: nil))
            return
        }
        if call.method == "dispose" {
            sessions.removeValue(forKey: identity)?.close(message: "JS 运行时会话已释放")
            result(nil)
            return
        }
        guard let id = args["id"] as? String,
              let timeout = args["timeoutMs"] as? NSNumber,
              timeout.doubleValue >= 1, timeout.doubleValue <= 300_000 else {
            result(FlutterError(code: "js_execution", message: "无效的 JS 请求或超时", details: nil))
            return
        }
        switch call.method {
        case "load":
            guard let script = args["script"] as? String, script.utf8.count <= IosJsSession.maximumBytes else {
                result(FlutterError(code: "js_execution", message: "JS 规则超过 8MiB 或无效", details: nil))
                return
            }
            sessions.removeValue(forKey: identity)?.close(message: "JS 规则已替换")
            let session = IosJsSession(identity: identity, channel: channel) { [weak self] closed in
                if self?.sessions[identity] === closed {
                    self?.sessions.removeValue(forKey: identity)
                }
            }
            sessions[identity] = session
            session.load(script: script, baseUrl: args["baseUrl"] as? String ?? "", id: id,
                         timeout: timeout.doubleValue / 1000, result: result)
        case "has", "call":
            guard let session = sessions[identity] else {
                result(FlutterError(code: "js_session_reset", message: "JS 会话已重置；可以重试", details: nil))
                return
            }
            session.invoke(operation: call.method, args: args, id: id,
                           timeout: timeout.doubleValue / 1000, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    deinit {
        channel.setMethodCallHandler(nil)
        for session in sessions.values {
            session.close(message: "JS 运行时已释放", notifyOwner: false)
        }
    }
}

private final class IosJsSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let maximumBytes = 8 * 1024 * 1024
    private let identity: String
    private let channel: FlutterMethodChannel
    private let closed: (IosJsSession) -> Void
    private let world: WKContentWorld
    private var webView: WKWebView?
    private var pending: (id: String, result: FlutterResult)?
    private var watchdog: DispatchWorkItem?
    private var source: String?
    private var initialNavigation = true
    private var isClosed = false
    // Host ids must belong to the current invocation, and settle only once.
    private var hostRequests = Set<String>()

    init(identity: String, channel: FlutterMethodChannel, closed: @escaping (IosJsSession) -> Void) {
        self.identity = identity
        self.channel = channel
        self.closed = closed
        world = WKContentWorld.world(name: "triomi-" + identity)
        super.init()
    }

    func load(script: String, baseUrl: String, id: String, timeout: TimeInterval,
              result: @escaping FlutterResult) {
        guard begin(id: id, timeout: timeout, result: result) else { return }
        source = script
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        controller.add(self, contentWorld: world, name: "triomi")
        let preamble = Self.preamble + "(" + Self.json(baseUrl)! + ", " + Self.json(id)! + ");"
        controller.addUserScript(WKUserScript(source: preamble, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: world))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        // No website is loaded. CSP blocks document networking/subframes and
        // the navigation delegate rejects subsequent navigations. Rules use
        // triomi.fetch; app cookies/credentials remain in the Dart host.
        view.loadHTMLString("""
            <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"><title>Triomi rule runtime</title>
            """, baseURL: nil)
    }

    func invoke(operation: String, args: [String: Any], id: String, timeout: TimeInterval,
                result: @escaping FlutterResult) {
        guard !isClosed, webView != nil, source == nil else {
            result(FlutterError(code: "js_session_reset", message: "JS 会话未就绪或已重置", details: nil))
            return
        }
        guard let function = args["function"] as? String,
              let encodedFunction = Self.json(function),
              let encodedID = Self.json(id) else {
            result(FlutterError(code: "js_execution", message: "无效的 JS 函数名", details: nil))
            return
        }
        if operation == "has" {
            guard begin(id: id, timeout: timeout, result: result) else { return }
            evaluate("typeof globalThis[\(encodedFunction)] === 'function'") { [weak self] value, error in
                guard let self = self, self.pending?.id == id else { return }
                if error != nil {
                    self.finish(value: false)
                } else {
                    self.finish(value: value as? Bool ?? false)
                }
            }
        } else {
            guard let arguments = args["args"] as? [Any], let encodedArguments = Self.json(arguments),
                  encodedArguments.utf8.count <= Self.maximumBytes else {
                result(FlutterError(code: "js_execution", message: "JS 参数超过 8MiB 或无法编码", details: nil))
                return
            }
            guard begin(id: id, timeout: timeout, result: result) else { return }
            evaluate("__triomiInvoke(\(encodedID), \(encodedFunction), \(encodedArguments)); void 0") { [weak self] _, error in
                guard let self = self, self.pending?.id == id, let error = error else { return }
                self.finish(error: Self.scriptError(error))
            }
        }
    }

    private func begin(id: String, timeout: TimeInterval, result: @escaping FlutterResult) -> Bool {
        guard !isClosed, pending == nil else {
            result(FlutterError(code: "js_execution", message: "JS 会话已释放或正忙", details: nil))
            return false
        }
        pending = (id, result)
        let watchdog = DispatchWorkItem { [weak self] in
            guard self?.pending?.id == id else { return }
            self?.close(message: "iOS JS 执行超时，会话已销毁；可以重试")
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        return true
    }

    private func evaluate(_ script: String, completion: @escaping (Any?, Error?) -> Void) {
        guard let view = webView, !isClosed else { return }
        view.evaluateJavaScript(script, in: nil, in: world) { outcome in
            switch outcome {
            case .success(let value): completion(value, nil)
            case .failure(let error): completion(nil, error)
            }
        }
    }

    private func finish(value: Any? = nil, error: String? = nil) {
        guard let request = pending else { return }
        pending = nil
        watchdog?.cancel()
        watchdog = nil
        // A rule that returns before its own host requests finish cannot carry
        // those promises into a later invocation with a different host owner.
        let hasOrphanedHostRequests = !hostRequests.isEmpty
        hostRequests.removeAll()
        if hasOrphanedHostRequests {
            close(message: "JS 调用结束后仍有宿主请求，会话已销毁")
        }
        if let error = error {
            request.result(FlutterError(code: "js_execution", message: error, details: nil))
        } else {
            request.result(value ?? NSNull())
        }
    }

    func close(message: String, notifyOwner: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        watchdog?.cancel()
        watchdog = nil
        let request = pending
        pending = nil
        source = nil
        hostRequests.removeAll()
        if let view = webView {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "triomi", contentWorld: world)
            view.configuration.userContentController.removeAllUserScripts()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.stopLoading()
            view.removeFromSuperview()
        }
        webView = nil
        if notifyOwner {
            closed(self)
            channel.invokeMethod("reset", arguments: ["session": identity])
        }
        request?.result(FlutterError(code: "js_session_reset", message: message, details: nil))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isClosed, message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        guard text.utf8.count <= Self.maximumBytes,
              let data = text.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            close(message: "JS 消息超过 8MiB 或格式无效，会话已销毁")
            return
        }
        guard let parentID = envelope["parentId"] as? String, pending?.id == parentID else { return }
        switch envelope["kind"] as? String {
        case "result":
            if envelope["ok"] as? Bool == true {
                finish(value: envelope["value"])
            } else {
                finish(error: envelope["error"] as? String ?? "JS 执行失败")
            }
        case "host":
            guard let id = envelope["id"] as? String, let payload = envelope["payload"] as? [String: Any],
                  hostRequests.insert(id).inserted else {
                close(message: "无效的 JS 宿主请求，会话已销毁")
                return
            }
            channel.invokeMethod("host", arguments: ["session": identity, "parentId": parentID,
                                                      "id": id, "payload": payload]) { [weak self] response in
                guard let self = self, !self.isClosed, self.pending?.id == parentID,
                      self.hostRequests.remove(id) != nil else { return }
                let reply = response as? [String: Any] ?? ["error": "宿主通道调用失败"]
                guard let encoded = Self.json(reply), encoded.utf8.count <= Self.maximumBytes,
                      let encodedID = Self.json(id) else {
                    self.close(message: "宿主响应超过 8MiB 或无法编码，会话已销毁")
                    return
                }
                self.evaluate("__triomiResolve(\(encodedID), \(encoded)); void 0") { [weak self] _, error in
                    guard let self = self, self.pending?.id == parentID, let error = error else { return }
                    self.finish(error: error.localizedDescription)
                }
            }
        default:
            close(message: "无效的 JS 消息，会话已销毁")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed, let script = source, let id = pending?.id else { return }
        initialNavigation = false
        source = nil
        // Append a void expression so functions/promises at the end of a rule
        // do not become unsupported native evaluateJavaScript return values.
        evaluate(script + "\n;void 0\n//# sourceURL=triomi-rule.js") { [weak self] _, error in
            guard let self = self, self.pending?.id == id else { return }
            if let error = error {
                self.close(message: "JS 规则加载失败：" + Self.scriptError(error))
            } else {
                self.finish(value: true)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(initialNavigation && navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        close(message: "JS 运行环境加载失败：" + error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        close(message: "JS 运行环境加载失败：" + error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(message: "iOS 已结束 JS WebContent，会话已销毁；可以重试")
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    private static func scriptError(_ error: Error) -> String {
        let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        return detail ?? error.localizedDescription
    }

    private static func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let preamble = #"""
    (function (baseUrl, loadId) {
      'use strict';
      var active = loadId;
      var sequence = 0;
      var pending = Object.create(null);
      var post = window.webkit.messageHandlers.triomi.postMessage.bind(window.webkit.messageHandlers.triomi);
      function send(message) { post(JSON.stringify(message)); }
      function host(payload) {
        var parentId = active;
        if (parentId === null) return Promise.reject(new Error('JS 请求已结束'));
        return new Promise(function (resolve, reject) {
          var id = 'host-' + (++sequence);
          pending[id] = { resolve: resolve, reject: reject, parentId: parentId };
          send({ kind: 'host', parentId: parentId, id: id, payload: payload });
        });
      }
      globalThis.__triomiResolve = function (id, reply) {
        var request = pending[id];
        if (!request) return;
        delete pending[id];
        if (request.parentId !== active) {
          request.reject(new Error('JS 请求已结束'));
        } else if (reply.error) {
          request.reject(new Error(String(reply.error)));
        } else {
          request.resolve(reply.value);
        }
      };
      globalThis.triomi = {
        baseUrl: baseUrl,
        fetch: function (url, options) {
          options = options || {};
          return host({ op: 'fetch', url: String(url), method: options.method || 'GET',
            headers: options.headers || {},
            body: options.body === undefined || options.body === null ? null : String(options.body),
            bodyType: options.bodyType || null });
        },
        select: function (html, selector, fields, baseUrl) {
          return host({ op: 'select', html: String(html), selector: String(selector),
            fields: fields === undefined ? null : fields, baseUrl: baseUrl || null });
        },
        value: function (html, selector, attr, baseUrl) {
          return host({ op: 'value', html: String(html), selector: String(selector),
            attr: attr || 'text', baseUrl: baseUrl || null });
        },
        values: function (html, selector, attr, baseUrl) {
          return host({ op: 'values', html: String(html), selector: String(selector),
            attr: attr || 'text', baseUrl: baseUrl || null });
        },
        // Never forward rule logs: they may contain credentials and bodies.
        log: function () {}
      };
      globalThis.__triomiInvoke = async function (id, name, args) {
        active = id;
        var result;
        try {
          var fn = globalThis[name];
          if (typeof fn !== 'function') throw new Error('TRIOMI_NO_FUNCTION|' + name);
          var value = await fn.apply(null, args);
          result = { kind: 'result', parentId: id, ok: true,
                     value: value === undefined ? null : value };
          // Serialization belongs inside the try: cyclic values, BigInt and
          // throwing toJSON methods are visible JS errors, not lost results.
          result = JSON.stringify(result);
        } catch (error) {
          var message = error && error.message ? error.message : String(error);
          result = JSON.stringify({ kind: 'result', parentId: id, ok: false, error: message });
        } finally {
          active = null;
        }
        post(result);
      };
    })
    """#
}
