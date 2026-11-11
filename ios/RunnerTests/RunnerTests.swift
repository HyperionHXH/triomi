import Darwin
import CFNetwork
import CryptoKit
import AVFoundation
import Flutter
import MediaPlayer
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

  private func invokeUpdate(_ bridge: IosPlatformBridge, _ method: String, _ arguments: [String: Any] = [:]) -> Any? {
    let done = expectation(description: "app-update/" + method)
    var value: Any?
    bridge.handleAppUpdate(FlutterMethodCall(methodName: method, arguments: arguments)) {
      value = $0; done.fulfill()
    }
    wait(for: [done], timeout: 15)
    return value
  }

  private func updatePlist(revision: Int = 2) throws -> [String: Any] {
    var plist = try XCTUnwrap(Bundle.main.infoDictionary)
    plist["CFBundleExecutable"] = "Runner"
    plist["CFBundlePackageType"] = "APPL"
    plist["TriomiIosRevision"] = revision
    return plist
  }

  private func inspectUpdate(_ bridge: IosPlatformBridge, path: String,
                             plist: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary,
                             manifestChange: [String: Any] = [:]) throws -> Any? {
    let payload = try Data(contentsOf: URL(fileURLWithPath: path))
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    var manifest: [String: Any] = ["platform": "ios", "packageName": Bundle.main.bundleIdentifier!,
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")!,
      "versionCode": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String)!,
      "iosRevision": 2, "sha256": hash]
    manifest.merge(manifestChange) { _, new in new }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
    return invokeUpdate(bridge, "inspectIos", ["path": path, "sha256": hash,
      "manifest": manifest, "plist": FlutterStandardTypedData(bytes: data)])
  }

  func testIosUpdaterReadsInstalledBundleRatherThanDownloadedRevision() throws {
    let bridge = try makeBridge()
    let current = try XCTUnwrap(invokeUpdate(bridge, "current") as? [String: Any])
    XCTAssertEqual(current["packageName"] as? String, Bundle.main.bundleIdentifier)
    XCTAssertEqual(current["version"] as? String, "0.15.4")
    XCTAssertEqual(current["versionCode"] as? Int, 198)
    XCTAssertEqual(current["iosRevision"] as? Int, 1)
    XCTAssertEqual((current["sha256"] as? String)?.count, 64)
  }

  func testIosUpdaterParsesBinaryAndXmlPlistAndMatchesExactIdentity() throws {
    let bridge = try makeBridge()
    let path = try XCTUnwrap(invokeUpdate(bridge, "beginIosStage") as? String)
    defer { _ = invokeUpdate(bridge, "discardIos", ["path": path]) }
    // Archive structure is validated by Dart before invoking native inspection.
    try Data("private integrity fixture".utf8).write(to: URL(fileURLWithPath: path))
    for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
      let identity = try XCTUnwrap(try inspectUpdate(bridge, path: path, plist: updatePlist(), format: format) as? [String: Any])
      XCTAssertEqual(identity["iosRevision"] as? Int, 2)
      XCTAssertEqual(identity["versionCode"] as? Int, 198)
      XCTAssertEqual(identity["platform"] as? String, "ios")
    }
    let changes: [[String: Any]] = [
      ["CFBundleIdentifier": "org.other.application"],
      ["CFBundleShortVersionString": "0.15.3"],
      ["CFBundleVersion": "197"],
      ["CFBundleExecutable": "Other"],
      ["TriomiIosRevision": 3],
      ["TriomiIosRevision": true],
      ["TriomiIosRevision": "2"],
      ["TriomiIosRevision": 2.5],
      ["CFBundleShortVersionString": "999999999999999999999.0.0"],
    ]
    for change in changes {
      var plist = try updatePlist()
      plist.merge(change) { _, new in new }
      XCTAssertTrue(try inspectUpdate(bridge, path: path, plist: plist) is FlutterError)
    }
    XCTAssertTrue(try inspectUpdate(bridge, path: path, plist: updatePlist(),
      manifestChange: ["iosRevision": 9]) is FlutterError)
  }

  func testIosUpdaterRejectsChangedPayloadAndSameRevisionBeforePresentingHandoff() throws {
    let bridge = try makeBridge()
    let path = try XCTUnwrap(invokeUpdate(bridge, "beginIosStage") as? String)
    let url = URL(fileURLWithPath: path)
    defer { _ = invokeUpdate(bridge, "discardIos", ["path": path]) }
    try Data("original verified fixture".utf8).write(to: url)
    let offered = try XCTUnwrap(try inspectUpdate(bridge, path: path, plist: updatePlist()) as? [String: Any])
    let hash = try XCTUnwrap(offered["sha256"] as? String)
    XCTAssertTrue(invokeUpdate(bridge, "handoffIos", ["path": path, "sha256": hash, "consent": false]) is FlutterError)
    try Data("changed after inspection".utf8).write(to: url)
    XCTAssertTrue(invokeUpdate(bridge, "handoffIos", ["path": path, "sha256": hash, "consent": true]) is FlutterError)
    let installedRevision = (Bundle.main.object(forInfoDictionaryKey: "TriomiIosRevision") as? NSNumber)?.intValue ?? 0
    let same = try XCTUnwrap(try inspectUpdate(bridge, path: path,
      plist: updatePlist(revision: installedRevision), manifestChange: ["iosRevision": installedRevision]) as? [String: Any])
    XCTAssertTrue(invokeUpdate(bridge, "handoffIos", ["path": path, "sha256": same["sha256"]!, "consent": true]) is FlutterError)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  func testIosUpdaterPinsIpaUntilCancelledShareCompletion() throws {
    let bridge = try makeBridge()
    let path = try XCTUnwrap(invokeUpdate(bridge, "beginIosStage") as? String)
    let url = URL(fileURLWithPath: path)
    var activeSheet: UIActivityViewController?
    defer {
      activeSheet?.completionWithItemsHandler?(nil, false, nil, nil)
      activeSheet?.dismiss(animated: false)
      _ = invokeUpdate(bridge, "discardIos", ["path": path])
    }
    try Data("verified share lease fixture".utf8).write(to: url)
    let identity = try XCTUnwrap(try inspectUpdate(bridge, path: path, plist: updatePlist()) as? [String: Any])
    XCTAssertEqual(invokeUpdate(bridge, "handoffIos", ["path": path,
      "sha256": identity["sha256"]!, "consent": true]) as? Bool, true)
    let sheet = try XCTUnwrap(IosPlatformBridge.presenter() as? UIActivityViewController)
    activeSheet = sheet
    XCTAssertEqual(invokeUpdate(bridge, "discardIos", ["path": path]) as? Bool, false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    let cancelled = expectation(description: "cancelled IPA share sheet")
    sheet.dismiss(animated: false) {
      // Drive UIKit's cancellation boundary without selecting an external app.
      sheet.completionWithItemsHandler?(nil, false, nil, nil)
      cancelled.fulfill()
    }
    wait(for: [cancelled], timeout: 15)
    activeSheet = nil
    XCTAssertEqual(invokeUpdate(bridge, "discardIos", ["path": path]) as? Bool, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testIosUpdaterNeverDiscardsForeignFiles() throws {
    let bridge = try makeBridge()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-update-" + UUID().uuidString + ".ipa")
    let data = Data("preserve original document".utf8)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertTrue(invokeUpdate(bridge, "discardIos", ["path": url.path]) is FlutterError)
    XCTAssertEqual(try Data(contentsOf: url), data)
  }

  func testRetiringPlayerCannotReclaimOrClearReplacementNowPlaying() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-owner-\(UUID().uuidString).wav")
    var wave = Data()
    func text(_ value: String) { wave.append(value.data(using: .ascii)!) }
    func number<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
    }
    text("RIFF"); number(UInt32(32036)); text("WAVEfmt "); number(UInt32(16))
    number(UInt16(1)); number(UInt16(1)); number(UInt32(8000)); number(UInt32(16000))
    number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(32000))
    wave.append(Data(repeating: 0, count: 32000))
    try wave.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let messenger = IosVideoTestMessenger()
    let old = IosVideoPlatformView(frame: .zero, viewId: -201, messenger: messenger)
    let next = IosVideoPlatformView(frame: .zero, viewId: -202, messenger: messenger)
    func call(_ view: IosVideoPlatformView, _ method: String, _ args: [String: Any] = [:]) {
      let done = expectation(description: method)
      view.handle(FlutterMethodCall(methodName: method, arguments: args)) {
        XCTAssertFalse($0 is FlutterError); done.fulfill()
      }
      wait(for: [done], timeout: 15)
    }
    var oldDisposed = false
    defer { if !oldDisposed { call(old, "dispose") }; call(next, "dispose") }
    for (view, title) in [(old, "retiring"), (next, "replacement")] {
      let prepared = expectation(description: "Prepare actual AVPlayer item")
      messenger.prepared = { prepared.fulfill() }
      call(view, "open", ["url": url.absoluteString, "mediaId": 1])
      wait(for: [prepared], timeout: 15)
      messenger.prepared = nil
      call(view, "setSystemMedia", ["mediaId": 1, "enabled": true, "title": title])
    }
    let center = MPNowPlayingInfoCenter.default()
    XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "replacement")
    call(old, "pause") // Also publishes a state, just like its periodic observer.
    XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "replacement")
    call(old, "setSystemMedia", ["mediaId": 0, "enabled": false])
    call(old, "dispose")
    oldDisposed = true
    XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "replacement")
    call(next, "setSystemMedia", ["mediaId": 1, "enabled": false])
    XCTAssertNil(center.nowPlayingInfo)
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
  private func invokeBackup(_ bridge: IosPlatformBridge, _ method: String, _ arguments: Any? = nil) -> Any? {
    let done = expectation(description: "backupDocuments/" + method)
    var value: Any?
    bridge.handleBackupDocuments(FlutterMethodCall(methodName: method, arguments: arguments)) {
      value = $0; done.fulfill()
    }
    wait(for: [done], timeout: 15)
    return value
  }

  func testBackupDocumentsReimportUsesOpaqueOriginalAndReleasesOnlyItsStage() throws {
    let files = FileManager.default
    let root = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .resolvingSymlinksInPath().appendingPathComponent("portable-native-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let original = root.appendingPathComponent("original.zip")
    let bytes = Data("reviewed original fixture".utf8)
    try bytes.write(to: original)
    try Data("not a backup".utf8).write(to: root.appendingPathComponent("skip.txt"))
    let linked = root.appendingPathComponent("linked.zip")
    try files.createSymbolicLink(at: linked, withDestinationURL: original)
    let directory = try IosExportDirectory.remember(root)
    defer { UserDefaults.standard.removeObject(forKey: "triomi.export-directory." + String(directory.dropFirst("ios-bookmark:".count))) }
    // New bridge resolves the persisted directory bookmark; no picker URL survives.
    let bridge = try makeBridge()
    let documents = try XCTUnwrap(invokeBackup(bridge, "list", ["treeUri": directory]) as? [[String: Any]])
    XCTAssertEqual(documents.count, 1)
    XCTAssertEqual(documents.first?["name"] as? String, "original.zip")
    let token = try XCTUnwrap(documents.first?["uri"] as? String)
    XCTAssertTrue(token.hasPrefix("ios-backup:"))
    XCTAssertFalse(token.contains(root.path))
    let path = try XCTUnwrap(invokeBackup(bridge, "stage", ["uri": token]) as? String)
    defer { _ = invokeBackup(bridge, "releaseStage", ["path": path]) }
    XCTAssertNotEqual(path, original.path)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    // Cleanup must not accept an arbitrary path, even one under our own sandbox.
    _ = invokeBackup(bridge, "releaseStage", ["path": original.path])
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    XCTAssertNil(IosBackupArtifactRegistry.acquire(owner: "stage-cleanup-test", cleanup: true))
    XCTAssertEqual((invokeBackup(bridge, "stage", ["uri": original.path]) as? FlutterError)?.code, "backup_document_failed")
    XCTAssertEqual((invokeBackup(bridge, "list", ["treeUri": "ios-bookmark:" + UUID().uuidString]) as? FlutterError)?.code, "backup_document_failed")
    let wrongHash = String(repeating: "0", count: 64)
    XCTAssertEqual((invokeBackup(bridge, "delete", ["uri": token, "sha256": wrongHash]) as? FlutterError)?.code, "backup_document_failed")
    XCTAssertTrue(files.fileExists(atPath: original.path))
    _ = invokeBackup(bridge, "releaseStage", ["path": path])
    XCTAssertFalse(files.fileExists(atPath: path))
    XCTAssertTrue(files.fileExists(atPath: original.path))
    // Change after review: the stage's old digest must never authorize deletion.
    let reviewedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let other = root.appendingPathComponent("other.zip")
    try bytes.write(to: other)
    try files.removeItem(at: original)
    try files.createSymbolicLink(at: original, withDestinationURL: other)
    XCTAssertEqual((invokeBackup(bridge, "delete", ["uri": token, "sha256": reviewedHash]) as? FlutterError)?.code, "backup_document_failed")
    XCTAssertEqual(try Data(contentsOf: other), bytes)
    try files.removeItem(at: original)
    let replacement = Data("replacement original".utf8)
    try replacement.write(to: original)
    XCTAssertEqual((invokeBackup(bridge, "delete", ["uri": token, "sha256": reviewedHash]) as? FlutterError)?.code, "backup_document_failed")
    XCTAssertEqual(try Data(contentsOf: original), replacement)
    let replacementHash = SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(invokeBackup(bridge, "delete", ["uri": token, "sha256": replacementHash]) as? Bool, true)
    XCTAssertFalse(files.fileExists(atPath: original.path))
  }

  func testBackupGrantRejectsSymlinkAndTraversalInputs() throws {
    let files = FileManager.default
    let root = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .resolvingSymlinksInPath().appendingPathComponent("grant-boundary-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let original = root.appendingPathComponent("original.zip")
    try Data("original".utf8).write(to: original)
    let link = root.appendingPathComponent("link.zip")
    try files.createSymbolicLink(at: link, withDestinationURL: original)
    let directoryLink = root.appendingPathComponent("directory-link")
    try files.createSymbolicLink(at: directoryLink, withDestinationURL: root)
    let documents = IosBackupDocuments()
    XCTAssertThrowsError(try documents.remember(link))
    XCTAssertThrowsError(try IosExportDirectory.remember(directoryLink))
    XCTAssertTrue(IosBackupDocuments.isPrivate(root))
    XCTAssertFalse(IosBackupDocuments.isPrivate(URL(fileURLWithPath: NSHomeDirectory() + "-other/backup")))
    let token = try documents.remember(original)
    XCTAssertTrue(token.hasPrefix("ios-backup:"))
    XCTAssertThrowsError(try documents.delete("ios-backup:../original.zip", expectedHash: String(repeating: "0", count: 64)))
    let directory = try IosExportDirectory.remember(root)
    let stage = try documents.stage(token, cache: root) { source, target in
      try files.copyItem(at: source, to: target)
    }
    defer { try? documents.releaseStage(stage) }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stage)), Data("original".utf8))
    try documents.releaseStage(original.path)
    XCTAssertTrue(files.fileExists(atPath: original.path))
    XCTAssertThrowsError(try documents.stage(token, cache: directoryLink) { _, _ in
      XCTFail("Symlink staging roots must never reach the copy callback")
    })
    try documents.releaseStage(stage)
    XCTAssertFalse(files.fileExists(atPath: stage))
    XCTAssertTrue(files.fileExists(atPath: original.path))
    defer { UserDefaults.standard.removeObject(forKey: "triomi.export-directory." + String(directory.dropFirst("ios-bookmark:".count))) }
    XCTAssertThrowsError(try IosExportDirectory.write(["treeUri": directory, "fileName": "export.zip", "sourcePath": link.path]))
    XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
  }


  func testOversizedBackupIsRejectedBeforeAnySnapshotBytesAreCopied() throws {
    let files = FileManager.default
    let root = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .resolvingSymlinksInPath().appendingPathComponent("backup-size-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let original = root.appendingPathComponent("growing.zip")
    try Data("initial reviewed bytes".utf8).write(to: original)
    let documents = IosBackupDocuments()
    let token = try documents.remember(original)
    let handle = try FileHandle(forWritingTo: original)
    try handle.truncate(atOffset: UInt64(IosBackupDocuments.maxBackupBytes + 1))
    try handle.close()
    // Sparse metadata exercises 16 GiB + 1 without reading or allocating 16 GiB.
    XCTAssertThrowsError(try documents.remember(original))
    XCTAssertThrowsError(try documents.stage(token, cache: root) { _, _ in
      XCTFail("An oversized original must be rejected before the copy callback")
    })
    // The legacy pickBackupFile path and new document path share this exact
    // copy helper, whose preflight and streaming counter both use the limit.
    let bridge = try makeBridge()
    let target = root.appendingPathComponent("must-not-be-created.zip")
    var total: Int64 = 0
    XCTAssertThrowsError(try bridge.copyFile(original, to: target,
      limit: IosBackupDocuments.maxBackupBytes, total: &total,
      totalLimit: Int64.max, reserve: 0))
    XCTAssertEqual(total, 0)
    XCTAssertFalse(files.fileExists(atPath: target.path))
    XCTAssertEqual(try files.attributesOfItem(atPath: original.path)[.size] as? NSNumber,
                   NSNumber(value: IosBackupDocuments.maxBackupBytes + 1))
  }

  func testWebKitCookiesRemainURLScopedAndPlaybackIsolated() throws {
    let host = "native-\(UUID().uuidString.lowercased()).invalid"
    let source = try XCTUnwrap(URL(string: "https://\(host)/private/page"))
    // Match the production persistent rule jar, with a unique host and scoped
    // cleanup. Playback below still exercises its separate ephemeral store.
    let sessions = IosWebSession()
    let store = sessions.ruleStore
    addTeardownBlock {
      let removed = self.expectation(description: "Only this test host's cookies removed")
      store.httpCookieStore.getAllCookies { cookies in
        let group = DispatchGroup()
        for cookie in cookies where IosWebSession.cookieDomainMatches(cookie, url: source) {
          group.enter()
          store.httpCookieStore.delete(cookie) { group.leave() }
        }
        group.notify(queue: .main) { removed.fulfill() }
      }
      self.wait(for: [removed], timeout: 15)
    }
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
    wait(for: [added], timeout: 60)
    let recreated = IosWebSession()
    let read = expectation(description: "Recreated bridge reads persistent native cookie")
    recreated.handle(FlutterMethodCall(methodName: "ruleCookieHeader", arguments: ["url": url.absoluteString]), presenter: nil) {
      XCTAssertEqual($0 as? String, "persistent=value"); read.fulfill()
    }
    wait(for: [read], timeout: 60)
    let removed = expectation(description: "Remove only smoke cookie")
    store.httpCookieStore.getAllCookies { cookies in
      let group = DispatchGroup()
      for cookie in cookies where cookie.domain == host {
        group.enter(); store.httpCookieStore.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { removed.fulfill() }
    }
    wait(for: [removed], timeout: 60)
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

private final class IosVideoTestMessenger: NSObject, FlutterBinaryMessenger {
  var prepared: (() -> Void)?
  func send(onChannel channel: String, message: Data?) {
    if let message = message,
       FlutterStandardMethodCodec.sharedInstance().decodeMethodCall(message).method == "prepared" {
      prepared?()
    }
  }
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    send(onChannel: channel, message: message)
    callback?(nil)
  }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 1 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
