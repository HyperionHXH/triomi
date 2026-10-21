import Darwin
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
    wait(for: [stored], timeout: 15)

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

  func testVideoBrightnessReadsSystemAndRestoresOnRelease() throws {
    let bridge = try makeBridge()
    let original = UIScreen.main.brightness
    defer { _ = invoke(bridge, "videoPolicy", ["owner": "brightness-test", "active": false]) }
    let before = try XCTUnwrap(invoke(bridge, "getVideoBrightness") as? Double)
    XCTAssertEqual(before, Double(original), accuracy: 0.001)
    _ = invoke(bridge, "videoPolicy", ["owner": "brightness-test", "active": true, "brightness": 0.35])
    let adjusted = try XCTUnwrap(invoke(bridge, "getVideoBrightness") as? Double)
    XCTAssertEqual(adjusted, 0.35, accuracy: 0.01)
    _ = invoke(bridge, "videoPolicy", ["owner": "brightness-test", "active": false])
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
