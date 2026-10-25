import Darwin
import CFNetwork
import AVFoundation
import Flutter
import UIKit
import WebKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  private func makeBridge() throws -> IosPlatformBridge {
    let controllers = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .compactMap { $0.rootViewController as? FlutterViewController }
    let delegate = UIApplication.shared.delegate as? FlutterAppDelegate
    let controller = try XCTUnwrap(controllers.first ??
      (delegate?.window?.rootViewController as? FlutterViewController))
    return IosPlatformBridge(messenger: controller.binaryMessenger,
                             channelName: "triomi/platform-test-" + UUID().uuidString)
  }

  private func invoke(_ bridge: IosPlatformBridge, _ method: String, _ arguments: Any? = nil) -> Any? {
    let done = expectation(description: method)
    var value: Any?
    bridge.handle(FlutterMethodCall(methodName: method, arguments: arguments)) {
      value = $0; done.fulfill()
    }
    wait(for: [done], timeout: 15)
    return value
  }

  func testExportBookmarkPersistsAndNeverOverwritesExistingDocument() throws {
    let files = FileManager.default
    let root = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .resolvingSymlinksInPath().appendingPathComponent("native-smoke-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let token = try IosExportDirectory.remember(root)
    defer { UserDefaults.standard.removeObject(forKey: "triomi.export-directory." + String(token.dropFirst("ios-bookmark:".count))) }
    let firstBridge = try makeBridge()
    let original = Data("first document".utf8)
    let firstValue = invoke(firstBridge, "writeToTree", ["treeUri": token, "fileName": "backup.zip", "bytes": FlutterStandardTypedData(bytes: original)])
    let first = try XCTUnwrap((firstValue as? String).flatMap(URL.init(string:)))
    XCTAssertTrue(first.isFileURL)
    XCTAssertEqual(try Data(contentsOf: first), original)

    // A fresh bridge must resolve native persisted bookmark data, not retain a
    // picker URL in memory. A name collision returns the actual new document.
    let secondBridge = try makeBridge()
    let source = root.appendingPathComponent("source.zip")
    let replacement = Data("second document".utf8)
    try replacement.write(to: source)
    let secondValue = invoke(secondBridge, "writeToTree", ["treeUri": token, "fileName": "backup.zip", "sourcePath": source.path])
    let second = try XCTUnwrap((secondValue as? String).flatMap(URL.init(string:)))
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Data(contentsOf: first), original)
    XCTAssertEqual(try Data(contentsOf: second), replacement)
    XCTAssertTrue(second.lastPathComponent.hasPrefix("backup ("))
    let traversal = invoke(secondBridge, "writeToTree", ["treeUri": token, "fileName": "../escape.zip", "bytes": FlutterStandardTypedData(bytes: original)])
    XCTAssertEqual((traversal as? FlutterError)?.code, "write_failed")
    let free = invoke(secondBridge, "availableDiskBytes", ["path": root.path]) as? NSNumber
    XCTAssertGreaterThan(try XCTUnwrap(free).int64Value, 0)
  }

  func testWebKitCookiesRemainURLScopedAndPlaybackIsolated() throws {
    let host = "native-\(UUID().uuidString.lowercased()).invalid"
    let source = try XCTUnwrap(URL(string: "https://\(host)/private/page"))
    let store = WKWebsiteDataStore.nonPersistent()
    let sessions = IosWebSession(ruleStore: store)
    let stored = expectation(description: "Native WebKit Set-Cookie completion")
    sessions.handle(FlutterMethodCall(methodName: "ruleStoreCookies", arguments: ["url": source.absoluteString, "cookies": [
      "session=secret; Path=/; Secure; HttpOnly",
      "private=only-private; Path=/private; Secure",
      "foreign=never; Domain=other.invalid; Path=/; Secure",
      "__Secure-invalid=never; Path=/",
      "__Host-invalid=never; Domain=\(host); Path=/; Secure",
    ]]), presenter: nil) { value in
      XCTAssertEqual(value as? Bool, true); stored.fulfill()
    }
    wait(for: [stored], timeout: 45)

    func header(_ method: String, _ value: String) -> String? {
      let done = expectation(description: method + value)
      var answer: String?
      sessions.handle(FlutterMethodCall(methodName: method, arguments: ["url": value]), presenter: nil) {
        answer = $0 as? String; done.fulfill()
      }
      wait(for: [done], timeout: 15)
      return answer
    }
    let privateHeader = try XCTUnwrap(header("ruleCookieHeader", source.absoluteString))
    XCTAssertTrue(privateHeader.contains("session=secret")) // Native access includes HttpOnly.
    XCTAssertTrue(privateHeader.contains("private=only-private"))
    XCTAssertFalse(privateHeader.contains("never"))
    XCTAssertEqual(header("ruleCookieHeader", "https://\(host)/public"), "session=secret")
    XCTAssertNil(header("ruleCookieHeader", "https://sub.\(host)/private/page"))
    XCTAssertNil(header("videoCookieHeader", source.absoluteString))
    let insecure = expectation(description: "Secure cookies never reach HTTP playback")
    IosWebSession.cookieHeader(url: try XCTUnwrap(URL(string: "http://\(host)/private/page")), store: store) {
      XCTAssertNil($0); insecure.fulfill()
    }
    wait(for: [insecure], timeout: 15)
  }

  func testHttpCacheClearPreservesSourceAndVideoCookiesAndDOMStorage() throws {
    let store = WKWebsiteDataStore.nonPersistent()
    let video = WKWebsiteDataStore.nonPersistent()
    let sessions = IosWebSession(ruleStore: store, videoStore: video)
    let url = try XCTUnwrap(URL(string: "https://cache-\(UUID().uuidString.lowercased()).invalid/"))
    let cookies = expectation(description: "Source and playback fixture cookies stored")
    cookies.expectedFulfillmentCount = 2
    IosWebSession.storeCookies(["rule=session; Path=/; Secure; HttpOnly"], url: url, store: store) { cookies.fulfill() }
    IosWebSession.storeCookies(["video=session; Path=/; Secure; HttpOnly"], url: url, store: video) { cookies.fulfill() }
    wait(for: [cookies], timeout: 15)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    let probe = IosMediaScriptProbe(configuration: configuration)
    let loaded = expectation(description: "WebKit source DOM storage populated")
    probe.finished = { value in
      XCTAssertEqual(value as? String, "saved"); loaded.fulfill()
    }
    probe.action = "localStorage.setItem('triomi-cache-fixture','kept'); window.webkit.messageHandlers.fixtureDone.postMessage('saved');"
    probe.web.loadHTMLString("<html><body>cache fixture</body></html>", baseURL: url)
    wait(for: [loaded], timeout: 15)
    let cleared = expectation(description: "Public WebKit HTTP cache deletion completed")
    sessions.clearHttpCache { cleared.fulfill() }
    wait(for: [cleared], timeout: 15)
    let retained = expectation(description: "Cookie and DOM state retained")
    retained.expectedFulfillmentCount = 3
    IosWebSession.cookieHeader(url: url, store: store) { XCTAssertEqual($0, "rule=session"); retained.fulfill() }
    IosWebSession.cookieHeader(url: url, store: video) { XCTAssertEqual($0, "video=session"); retained.fulfill() }
    probe.web.evaluateJavaScript("localStorage.getItem('triomi-cache-fixture')") { value, error in
      XCTAssertNil(error); XCTAssertEqual(value as? String, "kept"); retained.fulfill()
    }
    wait(for: [retained], timeout: 15)
  }

  func testResolverDetectsSuffixlessHlsWithoutConsumingPlayerBodyOrAddingCookies() throws {
    let probe = IosMediaScriptProbe()
    let complete = expectation(description: "Actual WebKit fetch detection")
    probe.finished = { value in
      let result = value as? [String: Any]
      XCTAssertEqual(result?["body"] as? String, "#EXTM3U\n#EXT-X-VERSION:3")
      let reports = result?["reports"] as? [[String: Any]] ?? []
      XCTAssertEqual(reports.count, 1)
      XCTAssertEqual(reports.first?["url"] as? String, "https://triomi-resolver.invalid/manifest?id=1")
      XCTAssertEqual(reports.first?["mimeType"] as? String, "application/vnd.apple.mpegurl")
      XCTAssertEqual(reports.first?["omitCookies"] as? Bool, true)
      complete.fulfill()
    }
    probe.bootstrap = """
      window.reports = [];
      window.fetch = () => {
        const response = new Response('#EXTM3U\\n#EXT-X-VERSION:3', {headers:{'Content-Type':'application/octet-stream'}});
        Object.defineProperty(response, 'url', {value:'https://triomi-resolver.invalid/manifest?id=1'});
        return Promise.resolve(response);
      };
      """
    probe.action = """
      fetch('/manifest?id=1', {credentials:'omit'}).then(response => response.text()).then(body => {
        setTimeout(() => window.webkit.messageHandlers.fixtureDone.postMessage({body,reports:window.reports}), 100);
      });
      """
    probe.installDetection(legacy: false)
    probe.web.loadHTMLString("<html><body>fixture</body></html>", baseURL: URL(string: "https://triomi-resolver.invalid/"))
    wait(for: [complete], timeout: 15)
  }

  func testLegacyIframeQueryExtractionIsRuleOptIn() throws {
    for legacy in [false, true] {
      let probe = IosMediaScriptProbe()
      let complete = expectation(description: "Legacy iframe rule \(legacy)")
      probe.finished = { value in
        let reports = value as? [[String: Any]] ?? []
        XCTAssertEqual(reports.count, legacy ? 1 : 0)
        if legacy { XCTAssertEqual(reports.first?["url"] as? String, "https://media.invalid/episode.m3u8") }
        complete.fulfill()
      }
      probe.bootstrap = "window.reports = [];"
      probe.action = """
        const frame = document.createElement('iframe');
        frame.src = 'https://parser.invalid/embed?url=https%3A%2F%2Fmedia.invalid%2Fepisode.m3u8';
        document.body.appendChild(frame);
        setTimeout(() => window.webkit.messageHandlers.fixtureDone.postMessage(window.reports), 100);
        """
      probe.installDetection(legacy: legacy)
      probe.web.loadHTMLString("<html><body>fixture</body></html>", baseURL: URL(string: "https://triomi-resolver.invalid/"))
      wait(for: [complete], timeout: 15)
    }
  }

  func testResolverCancellationIsScopedToItsRequestOwner() throws {
    let resolver = IosVideoResolver(store: .nonPersistent())
    let cancelled = expectation(description: "Only matching owner cancels native resolver")
    var returned = false
    resolver.resolve(url: try XCTUnwrap(URL(string: "https://triomi-resolver.invalid/")), args: ["requestId": "new-download"]) { value in
      returned = true
      XCTAssertEqual((value as? FlutterError)?.code, "resolve_cancelled")
      cancelled.fulfill()
    }
    resolver.cancel(requestId: "stale-download")
    XCTAssertFalse(returned)
    resolver.cancel(requestId: "new-download")
    wait(for: [cancelled], timeout: 1)
  }

  func testResolverBridgeReturnsHlsMetadataAndHonorsObservedCookieOmission() throws {
    let store = WKWebsiteDataStore.nonPersistent()
    let url = try XCTUnwrap(URL(string: "https://triomi-resolver.invalid/extensionless"))
    let stored = expectation(description: "Native media cookie fixture")
    IosWebSession.storeCookies(["media=private; Path=/; Secure; HttpOnly"], url: url, store: store) { stored.fulfill() }
    wait(for: [stored], timeout: 45)
    for omit in [false, true] {
      let resolver = IosVideoResolver(store: store)
      let complete = expectation(description: "Resolver metadata reaches Flutter callback \(omit)")
      var returned = false
      resolver.resolve(url: url, args: ["requestId": "metadata-\(omit)"]) { value in
        returned = true
        let result = value as? [String: Any]
        XCTAssertEqual(result?["url"] as? String, url.absoluteString)
        XCTAssertEqual(result?["mimeType"] as? String, "application/vnd.apple.mpegurl")
        XCTAssertEqual(result?["omitCookies"] as? Bool == true, omit)
        let headers = result?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Cookie"], omit ? nil : "media=private")
        XCTAssertNil(headers?["Referer"])
        complete.fulfill()
      }
      resolver.receiveMedia(["url": url.absoluteString])
      XCTAssertFalse(returned, "A plain suffixless link is not playable-media evidence")
      resolver.receiveMedia(["url": url.absoluteString, "mimeType": "application/vnd.apple.mpegurl", "omitCookies": omit,
                             "page": "https://triomi-resolver.invalid/player", "policy": "no-referrer"])
      wait(for: [complete], timeout: 15)
    }
  }

  func testProxyEndpointFormattingRejectsCredentialsAndKeepsIPv6() throws {
    let route = try IosSystemProxyRequest.httpRoute([
      kCFProxyHostNameKey as String: "::1", kCFProxyPortNumberKey as String: 7890,
    ])
    XCTAssertEqual(route["proxy"] as? String, "[::1]:7890")
    for invalid in [
      [kCFProxyHostNameKey as String: "proxy.invalid", kCFProxyPortNumberKey as String: 8080, kCFProxyUsernameKey as String: "private"],
      [kCFProxyHostNameKey as String: "user:secret@proxy.invalid", kCFProxyPortNumberKey as String: 8080],
      [kCFProxyHostNameKey as String: "proxy.invalid", kCFProxyPortNumberKey as String: 70000],
    ] as [[String: Any]] { XCTAssertThrowsError(try IosSystemProxyRequest.httpRoute(invalid)) }
    let bridge = try makeBridge()
    for url in ["https://user:secret@source.invalid/", "file:///private/source"] {
      XCTAssertEqual((invoke(bridge, "resolveSystemProxy", ["url": url]) as? FlutterError)?.code, "invalid_url")
    }
  }

  func testOSPacEvaluationSelectsEachDestinationWithoutProbingIt() throws {
    let script = """
      function FindProxyForURL(url, host) {
        if (host === 'bypass.invalid') return 'DIRECT';
        return 'PROXY proxy.invalid:8080';
      }
      """
    for (host, expected) in [("bypass.invalid", true), ("source.invalid", false)] {
      let complete = expectation(description: "CFNetwork PAC evaluation for \(host)")
      IosSystemProxyRequest.resolve(url: try XCTUnwrap(URL(string: "https://\(host)/comments")), proxies: [[
        kCFProxyTypeKey as String: kCFProxyTypeAutoConfigurationJavaScript as String,
        kCFProxyAutoConfigurationJavaScriptKey as String: script,
      ]]) { value in
        let route = value as? [String: Any]
        XCTAssertEqual(route?["direct"] as? Bool, expected)
        if !expected { XCTAssertEqual(route?["proxy"] as? String, "proxy.invalid:8080") }
        complete.fulfill()
      }
      wait(for: [complete], timeout: 20)
    }
  }

  func testOSPacRetainsOrderedProxyAndDirectFailover() throws {
    let complete = expectation(description: "CFNetwork preserves its PAC failover list")
    IosSystemProxyRequest.resolve(url: try XCTUnwrap(URL(string: "https://source.invalid/comments")), proxies: [[
      kCFProxyTypeKey as String: kCFProxyTypeAutoConfigurationJavaScript as String,
      kCFProxyAutoConfigurationJavaScriptKey as String: "function FindProxyForURL(url, host) { return 'PROXY first.invalid:8080; PROXY second.invalid:8888; DIRECT'; }",
    ]]) { value in
      let route = value as? [String: Any]
      let routes = route?["routes"] as? [[String: Any]]
      XCTAssertEqual(route?["direct"] as? Bool, false)
      XCTAssertEqual(routes?.count, 3)
      if let routes = routes, routes.count == 3 {
        XCTAssertEqual(routes[0]["proxy"] as? String, "first.invalid:8080")
        XCTAssertEqual(routes[1]["proxy"] as? String, "second.invalid:8888")
        XCTAssertEqual(routes[2]["direct"] as? Bool, true)
      }
      complete.fulfill()
    }
    wait(for: [complete], timeout: 20)
  }

  func testPersistentWebKitSourceCookiesSurviveBridgeRecreation() throws {
    let host = "persist-\(UUID().uuidString.lowercased()).invalid"
    let url = try XCTUnwrap(URL(string: "https://\(host)/"))
    let store = WKWebsiteDataStore.default()
    let added = expectation(description: "Persistent app WebKit jar stores cookie")
    IosWebSession.storeCookies(["persistent=value; Path=/; Secure; HttpOnly; Max-Age=3600"], url: url, store: store) { added.fulfill() }
    wait(for: [added], timeout: 15)
    let recreated = IosWebSession()
    let read = expectation(description: "Recreated bridge reads persistent native cookie")
    recreated.handle(FlutterMethodCall(methodName: "ruleCookieHeader", arguments: ["url": url.absoluteString]), presenter: nil) {
      XCTAssertEqual($0 as? String, "persistent=value"); read.fulfill()
    }
    wait(for: [read], timeout: 15)
    let removed = expectation(description: "Remove only smoke cookie")
    store.httpCookieStore.getAllCookies { cookies in
      let group = DispatchGroup()
      for cookie in cookies where cookie.domain == host {
        group.enter(); store.httpCookieStore.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { removed.fulfill() }
    }
    wait(for: [removed], timeout: 15)
  }

  func testBackupLeaseExcludesCleanupAcrossOwnersAndOSDescriptors() throws {
    let owner = "native-smoke-\(UUID().uuidString)"
    let other = "other-\(UUID().uuidString)"
    defer { IosBackupArtifactRegistry.releaseOwner(owner); IosBackupArtifactRegistry.releaseOwner(other) }
    let first = try XCTUnwrap(IosBackupArtifactRegistry.acquire(owner: owner, cleanup: false))
    let nested = try XCTUnwrap(IosBackupArtifactRegistry.acquire(owner: other, cleanup: false))
    XCTAssertNil(IosBackupArtifactRegistry.acquire(owner: owner, cleanup: true))
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
    let fd = open(support.appendingPathComponent("triomi-backup-control/artifacts.lock").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { if fd >= 0 { close(fd) } }
    XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    IosBackupArtifactRegistry.release(token: first, owner: other)
    XCTAssertNil(IosBackupArtifactRegistry.acquire(owner: owner, cleanup: true))
    IosBackupArtifactRegistry.release(token: first, owner: owner)
    IosBackupArtifactRegistry.release(token: nested, owner: other)
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    XCTAssertNil(IosBackupArtifactRegistry.acquire(owner: owner, cleanup: false))
    flock(fd, LOCK_UN)
    let cleanup = try XCTUnwrap(IosBackupArtifactRegistry.acquire(owner: owner, cleanup: true))
    XCTAssertNil(IosBackupArtifactRegistry.acquire(owner: other, cleanup: false))
    IosBackupArtifactRegistry.release(token: cleanup, owner: owner)
    XCTAssertNotNil(IosBackupArtifactRegistry.acquire(owner: other, cleanup: false))
  }
  func testStorageConfigurationExcludesRootsAndExistingContent() throws {
    let result = try IosBackupArtifactGuard.configureStorage()
    for key in ["documentsPath", "supportPath"] { XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result[key] as? String))) }
    XCTAssertEqual(result["documentsExcluded"] as? Bool, true)
    XCTAssertEqual(result["supportExcluded"] as? Bool, true)
    let documents = URL(fileURLWithPath: try XCTUnwrap(result["documentsPath"] as? String))
    let probe = documents.appendingPathComponent("native-backup-probe-\(UUID().uuidString)")
    let bytes = Data("probe".utf8)
    try bytes.write(to: probe)
    defer { try? FileManager.default.removeItem(at: probe) }
    _ = try IosBackupArtifactGuard.configureStorage()
    XCTAssertEqual(try Data(contentsOf: probe), bytes)
    XCTAssertEqual(try documents.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  func testDownloadWakeOwnersDoNotReleaseReaderOrVideoWake() throws {
    let bridge = try makeBridge()
    _ = invoke(bridge, "keepScreenOn", true)
    _ = invoke(bridge, "videoPolicy", ["owner": "video", "active": true])
    _ = invoke(bridge, "downloadWake", ["owner": "download-a", "active": true])
    _ = invoke(bridge, "downloadWake", ["owner": "download-b", "active": true])
    _ = invoke(bridge, "downloadWake", ["owner": "download-a", "active": false])
    XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    _ = invoke(bridge, "downloadWake", ["owner": "download-b", "active": false])
    XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    _ = invoke(bridge, "videoPolicy", ["owner": "video", "active": false])
    XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    _ = invoke(bridge, "keepScreenOn", false)
    XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
  }

  func testVideoBrightnessReportsActualSystemValue() throws {
    let bridge = try makeBridge()
    let actual = try XCTUnwrap(invoke(bridge, "getVideoBrightness") as? Double)
    XCTAssertEqual(actual, Double(UIScreen.main.brightness), accuracy: 0.001)
    XCTAssertTrue((0...1).contains(actual))
  }

  func testVideoBrightnessRestoresOnReleaseWhenDisplaySupportsChanges() throws {
    let bridge = try makeBridge()
    let original = UIScreen.main.brightness
    let before = Double(original)
    defer {
      _ = invoke(bridge, "videoPolicy", ["owner": "brightness-test", "active": false])
      UIScreen.main.brightness = original
    }
    UIScreen.main.brightness = 0.35
    let directChange = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      abs(Double(UIScreen.main.brightness) - 0.35) < 0.01
    }, object: nil)
    let supported = XCTWaiter.wait(for: [directChange], timeout: 3) == .completed
    #if targetEnvironment(simulator)
    if !supported {
      throw XCTSkip("Direct UIScreen brightness setter is unsupported by this simulator; actual value is \(UIScreen.main.brightness). Physical display mutation remains unverified.")
    }
    #endif
    XCTAssertTrue(supported, "Direct UIScreen brightness changes must work before checking bridge mutation")
    UIScreen.main.brightness = original
    let baseline = expectation(for: NSPredicate { _, _ in
      abs(Double(UIScreen.main.brightness) - before) < 0.01
    }, evaluatedWith: nil)
    wait(for: [baseline], timeout: 5)
    _ = invoke(bridge, "videoPolicy", ["owner": "brightness-test", "active": true, "brightness": 0.35])
    let changed = expectation(for: NSPredicate { _, _ in
      abs(Double(UIScreen.main.brightness) - 0.35) < 0.01
    }, evaluatedWith: nil)
    wait(for: [changed], timeout: 5)
    let adjusted = try XCTUnwrap(invoke(bridge, "getVideoBrightness") as? Double)
    XCTAssertEqual(adjusted, 0.35, accuracy: 0.01)
    _ = invoke(bridge, "videoPolicy", ["owner": "brightness-test", "active": false])
    let restored = expectation(for: NSPredicate { _, _ in
      abs(Double(UIScreen.main.brightness) - before) < 0.01
    }, evaluatedWith: nil)
    wait(for: [restored], timeout: 5)
    XCTAssertEqual(Double(UIScreen.main.brightness), before, accuracy: 0.01)
  }

  func testPlaybackAudioSessionActivatesWithSupportedCategory() throws {
    try IosVideoAudioSession.acquire(-100)
    try IosVideoAudioSession.acquire(-101)
    defer { IosVideoAudioSession.release(-100); IosVideoAudioSession.release(-101) }
    let session = AVAudioSession.sharedInstance()
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .moviePlayback)
    XCTAssertFalse(session.categoryOptions.contains(.allowBluetooth))
    IosVideoAudioSession.release(-100)
    XCTAssertEqual(session.category, .playback)
  }
}

private final class IosMediaScriptProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let web: WKWebView
  var bootstrap = ""
  var action = ""
  var finished: ((Any) -> Void)?

  init(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
    web = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    web.navigationDelegate = self
    web.configuration.userContentController.add(self, name: "fixtureDone")
    web.configuration.userContentController.add(self, name: "triomiMedia")
  }

  func installDetection(legacy: Bool) {
    let controller = web.configuration.userContentController
    controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    controller.addUserScript(WKUserScript(source: IosVideoResolver.detectionScript(useLegacyParser: legacy), injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // Results arrive through fixtureDone; Promise/postMessage values cannot be
    // bridged by evaluateJavaScript. Keep script execution errors observable.
    webView.evaluateJavaScript("(function(){\n\(action)\n})(); null;") { _, error in
      XCTAssertNil(error)
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "triomiMedia", let value = message.body as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data: data, encoding: .utf8) {
      web.evaluateJavaScript("window.reports.push(\(json))", completionHandler: nil)
    } else if message.name == "fixtureDone" {
      web.stopLoading(); web.navigationDelegate = nil
      web.configuration.userContentController.removeAllScriptMessageHandlers()
      let callback = finished; finished = nil; callback?(message.body)
    }
  }
}
