import AVFoundation
import CFNetwork
import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers

/// Application-owned integrations. File providers are read through coordinated,
/// security-scoped URLs; Dart receives canonical private snapshots, never grants.
final class IosPlatformBridge: NSObject, UIDocumentPickerDelegate {
  private static let backupNameLock = NSLock()
  private static var lastBackupStamp: UInt64 = 0
  private let channel: FlutterMethodChannel
  private let cacheChannel: FlutterMethodChannel
  private let files = FileManager.default
  private let worker = DispatchQueue(label: "triomi.ios.files", qos: .userInitiated)
  private let web = IosWebSession()
  private let artifactOwner = UUID().uuidString
  private var picker: UIDocumentPickerViewController?
  private var pending: FlutterResult?
  private var pickerKind = ""
  private var copying = false
  private let cancellationLock = NSLock()
  private var cancelled = false
  private var readerAwake = false
  private var videoOwner: String?
  private var downloadOwners = Set<String>()
  private var originalBrightness: CGFloat?

  init(messenger: FlutterBinaryMessenger, channelName: String = "triomi/platform") {
    channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    cacheChannel = FlutterMethodChannel(name: channelName == "triomi/platform" ? "triomi/cache-management" : channelName + "/cache-management", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    cacheChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "clearBrowserHttpCache" { self.web.clearHttpCache { result(true) } }
      else { result(FlutterMethodNotImplemented) }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    cacheChannel.setMethodCallHandler(nil)
    IosBackupArtifactRegistry.releaseOwner(artifactOwner)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "resolveSystemProxy":
      guard let value = args["url"] as? String, let url = IosWebSession.webURL(value) else {
        result(FlutterError(code: "invalid_url", message: "A public HTTP(S) URL without credentials is required", details: nil)); return
      }
      IosSystemProxyRequest.resolve(url: url, result: result)
    case "pickBackupFile", "pickFontFile", "pickImage", "pickDirectory", "pickLocalComic":
      presentPicker(call.method, directory: args["directory"] as? Bool == true, result: result)
    case "cancelLocalComicPick":
      cancellationLock.lock(); cancelled = true; cancellationLock.unlock()
      if pickerKind == "pickLocalComic", !copying { picker?.dismiss(animated: true); finishPicker(nil) }
      result(nil)
    case "writeToTree":
      worker.async {
        do { let value = try IosExportDirectory.write(args); DispatchQueue.main.async { result(value.absoluteString) } }
        catch { DispatchQueue.main.async { result(Self.failure("write_failed", error)) } }
      }
    case "availableDiskBytes":
      guard let path = args["path"] as? String else { result(FlutterError(code: "invalid_args", message: "path is required", details: nil)); return }
      worker.async {
        do {
          let attributes = try self.files.attributesOfFileSystem(forPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
          DispatchQueue.main.async { result((attributes[.systemFreeSize] as? NSNumber)?.int64Value) }
        } catch { DispatchQueue.main.async { result(Self.failure("disk_unavailable", error)) } }
      }
    case "keepScreenOn":
      readerAwake = call.arguments as? Bool == true; updateIdleTimer(); result(true)
    case "downloadWake":
      guard let owner = args["owner"] as? String, !owner.isEmpty, let active = args["active"] as? Bool else { result(FlutterError(code: "invalid_args", message: "owner and active are required", details: nil)); return }
      if active { downloadOwners.insert(owner) } else { downloadOwners.remove(owner) }
      updateIdleTimer(); result(true)
    case "configureStorage":
      do { result(try IosBackupArtifactGuard.configureStorage()) }
      catch { result(Self.failure("storage_configuration_failed", error)) }
    case "videoPolicy": configureVideo(args, result: result)
    case "getVideoBrightness": result(Double(UIScreen.main.brightness))
    case "enterVideoPip": result(false)
    case "saveImageToGallery": saveImage(args, result: result)
    case "launchExternalUrl":
      guard let value = args["url"] as? String, let url = IosWebSession.webURL(value), UIApplication.shared.applicationState == .active else { result(FlutterError(code: "invalid_url", message: "Return to the app and use a public HTTP(S) URL", details: nil)); return }
      UIApplication.shared.open(url, options: [:]) { result($0) }
    case "ruleOpenSession", "ruleCookieHeader", "ruleStoreCookies", "videoCookieHeader", "resolveVideo", "resolveDownloadVideo", "cancelVideoResolve", "cancelDownloadVideoResolve":
      web.handle(call, presenter: Self.presenter(), result: result)
    case "scheduleBackgroundCheck", "backgroundCheckScheduled", "scheduleLocalBackups", "scheduleMangaUpdates", "canNotifyMangaUpdates", "mangaUpdateConstraints", "beginMangaUpdate", "beginDownloadQueue", "requestNotificationPermission": result(false)
    case "endMangaUpdate", "endDownloadQueue", "cancelMangaUpdate": result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }


  static func presenter() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private func presentPicker(_ kind: String, directory: Bool, result: @escaping FlutterResult) {
    guard pending == nil, !copying else {
      result(FlutterError(code: "busy", message: "A document selection is already active", details: nil)); return
    }
    guard let presenter = Self.presenter(), UIApplication.shared.applicationState == .active else {
      result(FlutterError(code: "activity_inactive", message: "Return to the app before selecting documents", details: nil)); return
    }
    let types: [UTType]
    switch kind {
    case "pickDirectory": types = [.folder]
    case "pickLocalComic": types = directory ? [.folder] : [.data, .image, .zip]
    case "pickImage": types = [.image]
    default: types = [.data]
    }
    let view = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    view.delegate = self
    view.allowsMultipleSelection = kind == "pickLocalComic" && !directory
    pending = result; pickerKind = kind; picker = view
    cancellationLock.lock(); cancelled = false; cancellationLock.unlock()
    presenter.present(view, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishPicker(nil) }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard !urls.isEmpty else { finishPicker(nil); return }
    let kind = pickerKind
    copying = true
    worker.async {
      var cleanup: URL?
      var artifactLease: String?
      defer {
        if let lease = artifactLease { IosBackupArtifactRegistry.release(token: lease, owner: self.artifactOwner) }
      }
      do {
        if kind == "pickBackupFile" || kind == "pickLocalComic" {
          guard let token = IosBackupArtifactRegistry.acquire(owner: self.artifactOwner, cleanup: false) else {
            throw Self.error("Backup storage is busy")
          }
          artifactLease = token
        }
        let value: Any
        if kind == "pickDirectory" {
          value = try IosExportDirectory.remember(urls[0])
        } else if kind == "pickLocalComic" {
          let root = try self.stagingDirectory()
          cleanup = root
          let paths = try self.snapshotComic(urls, root: root)
          try self.checkCancellation()
          value = ["paths": paths, "directory": root.path]
        } else if kind == "pickImage" {
          var image: [String: Any] = [:]
          try Self.readCoordinated(urls[0]) { url in
            let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard metadata.isRegularFile == true, (metadata.fileSize ?? 0) <= 64 * 1024 * 1024 else {
              throw Self.error("Select an image no larger than 64 MiB")
            }
            let bytes = try Data(contentsOf: url)
            guard !bytes.isEmpty, UIImage(data: bytes) != nil else { throw Self.error("The selected document is not a supported image") }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            image = ["bytes": FlutterStandardTypedData(bytes: bytes), "name": url.lastPathComponent, "mime": mime]
          }
          value = image
        } else {
          let ext = urls[0].pathExtension.lowercased()
          guard kind == "pickBackupFile" ? ext == "zip" : ["ttf", "otf"].contains(ext) else {
            throw Self.error(kind == "pickBackupFile" ? "Select a ZIP backup" : "Select a TTF or OTF font")
          }
          let cache = try self.cacheRoot()
          let target: URL
          if kind == "pickBackupFile" {
            var candidate: URL
            repeat {
              candidate = cache.appendingPathComponent("backup-import-\(Self.nextBackupStamp()).zip")
            } while self.files.fileExists(atPath: candidate.path)
            target = candidate
          } else {
            target = cache.appendingPathComponent("picked-font-\(UUID().uuidString).\(ext)")
          }
          cleanup = target
          var total: Int64 = 0
          try Self.readCoordinated(urls[0]) { url in
            try self.copyFile(url, to: target, limit: kind == "pickFontFile" ? 64 * 1024 * 1024 : Int64.max,
                              total: &total, totalLimit: Int64.max, reserve: 64 * 1024 * 1024)
          }
          value = target.resolvingSymlinksInPath().path
          // The review dialog outlives this native request. Match Android's
          // process-lifetime pin; cold-start cleanup may remove abandoned ZIPs.
          if kind == "pickBackupFile" { artifactLease = nil }
        }
        DispatchQueue.main.async { self.copying = false; self.finishPicker(value) }
      } catch {
        if let cleanup = cleanup { try? self.files.removeItem(at: cleanup) }
        let wasCancelled = self.isCancelled
        DispatchQueue.main.async {
          self.copying = false
          self.finishPicker(wasCancelled ? nil : Self.failure("read_failed", error))
        }
      }
    }
  }

  private func finishPicker(_ value: Any?) {
    let callback = pending
    pending = nil; picker = nil; pickerKind = ""
    callback?(value)
  }

  private var isCancelled: Bool {
    cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancelled
  }

  private func checkCancellation() throws {
    if isCancelled { throw Self.error("Selection cancelled") }
  }

  private func cacheRoot() throws -> URL {
    let root = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return root.resolvingSymlinksInPath()
  }

  private static func nextBackupStamp() -> UInt64 {
    backupNameLock.lock(); defer { backupNameLock.unlock() }
    let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    lastBackupStamp = max(now, lastBackupStamp + 1)
    return lastBackupStamp
  }

  private func stagingDirectory() throws -> URL {
    let parent = try cacheRoot().appendingPathComponent("local-comic-input", isDirectory: true)
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    let metadata = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard metadata.isDirectory == true, metadata.isSymbolicLink != true,
          parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().path else {
      throw Self.error("The private comic input directory is invalid")
    }
    let root = parent.appendingPathComponent("selection-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    return root.resolvingSymlinksInPath()
  }

  private func snapshotComic(_ urls: [URL], root: URL) throws -> [String] {
    guard urls.count <= 5000 else { throw Self.error("Select at most 5000 images or one ZIP/CBZ") }
    var paths = [String](); var seen = Set<String>(); var total: Int64 = 0
    var scanned = 0
    let imageExtensions = ["png", "jpg", "jpeg", "webp", "gif", "avif"]
    func copy(_ source: URL, relative: String, allowArchive: Bool) throws {
      try checkCancellation()
      guard relative.count <= 1024, relative.split(separator: "/").allSatisfy({ Self.safeName(String($0)) }),
            seen.insert(relative.lowercased()).inserted else { throw Self.error("Unsafe or duplicate document name") }
      let archive = ["zip", "cbz"].contains(source.pathExtension.lowercased())
      guard imageExtensions.contains(source.pathExtension.lowercased()) || (archive && allowArchive) else {
        throw Self.error("Only ZIP/CBZ or PNG/JPEG/WebP/GIF/AVIF is supported")
      }
      let destination = root.appendingPathComponent(relative)
      try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try copyFile(source, to: destination, limit: archive ? 1024 * 1024 * 1024 : 64 * 1024 * 1024,
                   total: &total, totalLimit: 2 * 1024 * 1024 * 1024, reserve: 16 * 1024 * 1024)
      paths.append(destination.path)
      guard paths.count <= 5000 else { throw Self.error("A comic may contain at most 5000 images") }
    }
    for input in urls {
      try Self.readCoordinated(input) { selected in
        let metadata = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard metadata.isSymbolicLink != true else { throw Self.error("Symbolic links are not accepted") }
        if metadata.isDirectory == true {
          guard urls.count == 1 else { throw Self.error("Select one image folder") }
          func collect(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 64 else { throw Self.error("Folder nesting exceeds 64 levels") }
            for item in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
              try checkCancellation(); scanned += 1
              guard scanned <= 20000, Self.safeName(item.lastPathComponent) else { throw Self.error("Unsafe folder or more than 20000 entries") }
              let info = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
              guard info.isSymbolicLink != true else { throw Self.error("Symbolic links are not accepted") }
              let name = prefix + item.lastPathComponent
              guard name.count <= 1024 else { throw Self.error("Folder path is too long") }
              if info.isDirectory == true { try collect(item, prefix: name + "/", depth: depth + 1) }
              else if info.isRegularFile == true, imageExtensions.contains(item.pathExtension.lowercased()) {
                try copy(item, relative: name, allowArchive: false)
              }
            }
          }
          try collect(selected, prefix: "", depth: 0)
        } else { try copy(selected, relative: selected.lastPathComponent, allowArchive: urls.count == 1) }
      }
    }
    guard !paths.isEmpty else { throw Self.error("The selection contains no supported images") }
    return paths
  }

  private func copyFile(_ source: URL, to target: URL, limit: Int64, total: inout Int64,
                        totalLimit: Int64, reserve: Int64) throws {
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Self.error("Only regular documents are accepted") }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard files.createFile(atPath: target.path, contents: nil) else { throw Self.error("Cannot create private snapshot") }
    let output = try FileHandle(forWritingTo: target)
    defer { try? output.close() }
    var copied: Int64 = 0
    while true {
      try checkCancellation()
      guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
      copied += Int64(chunk.count); total += Int64(chunk.count)
      guard copied <= limit, total <= totalLimit else { throw Self.error("The selected files exceed the import size limit") }
      let available = try files.attributesOfFileSystem(forPath: target.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber
      guard (available?.int64Value ?? 0) > reserve + Int64(chunk.count) else { throw Self.error("Insufficient private storage") }
      try output.write(contentsOf: chunk)
    }
    guard copied > 0 else { throw Self.error("The selected document is empty") }
    try output.synchronize()
  }

  static func readCoordinated(_ url: URL, body: (URL) throws -> Void) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?; var readError: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
      do { try body(readable) } catch { readError = error }
    }
    if let error = coordinationError { throw error }
    if let error = readError { throw error }
  }

  static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240 &&
      name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)) == nil
  }

  private func updateIdleTimer() {
    UIApplication.shared.isIdleTimerDisabled = readerAwake || videoOwner != nil || !downloadOwners.isEmpty
  }

  private func configureVideo(_ args: [String: Any], result: @escaping FlutterResult) {
    let active = args["active"] as? Bool == true
    let owner = args["owner"] as? String
    if !active && owner != videoOwner { result(true); return }
    if active {
      videoOwner = owner ?? "video"
      if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
      if let brightness = args["brightness"] as? Double, brightness >= 0 {
        UIScreen.main.brightness = CGFloat(min(1, max(0.05, brightness)))
      }
    } else {
      videoOwner = nil
      if let brightness = originalBrightness { UIScreen.main.brightness = brightness; originalBrightness = nil }
    }
    // AVPlayer owns audio-session leases. This policy only owns wake/brightness.
    updateIdleTimer(); result(true)
  }

  private func saveImage(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let bytes = args["bytes"] as? FlutterStandardTypedData, UIImage(data: bytes.data) != nil else {
      result(FlutterError(code: "invalid_args", message: "Valid image bytes are required", details: nil)); return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(FlutterError(code: "photo_permission", message: "Allow Triomi to add photos in Settings", details: nil)) }; return
      }
      var identifier: String?
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = (args["fileName"] as? String).flatMap { Self.safeName($0) ? $0 : nil } ?? "triomi.png"
        request.addResource(with: .photo, data: bytes.data, options: options)
        identifier = request.placeholderForCreatedAsset?.localIdentifier
      }) { success, error in
        DispatchQueue.main.async {
          if success, let identifier = identifier { result("ph://" + identifier) }
          else { result(FlutterError(code: "save_failed", message: error?.localizedDescription ?? "Photo could not be saved", details: nil)) }
        }
      }
    }
  }

  static func error(_ message: String) -> NSError {
    NSError(domain: "Triomi", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func failure(_ code: String, _ error: Error) -> FlutterError {
    FlutterError(code: code, message: error.localizedDescription, details: nil)
  }
}

/// Ask CFNetwork for the per-destination OS route, including exceptions and PAC.
/// PAC executes through the OS API; target headers and credentials never enter it.
final class IosSystemProxyRequest {
  private let url: URL
  private var pending: FlutterResult?
  private var source: CFRunLoopSource?
  private var remainingProxies: [[String: Any]] = []

  private init(url: URL, result: @escaping FlutterResult) { self.url = url; pending = result }

  static func resolve(url: URL, result: @escaping FlutterResult) {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { result(["direct": true]); return }
    let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()
    resolve(url: url, proxies: proxies as! [[String: Any]], result: result)
  }

  static func resolve(url: URL, proxies: [[String: Any]], result: @escaping FlutterResult) {
    let request = IosSystemProxyRequest(url: url, result: result)
    request.select(proxies, allowPAC: true)
  }

  private func select(_ proxies: [[String: Any]], allowPAC: Bool) {
    guard let proxy = proxies.first, let type = proxy[kCFProxyTypeKey as String] as? String else {
      finish(FlutterError(code: "system_proxy_failed", message: "The OS returned no proxy route", details: nil)); return
    }
    if type == kCFProxyTypeNone as String || type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String {
      do {
        let routes: [[String: Any]] = try proxies.map { entry in
          guard let kind = entry[kCFProxyTypeKey as String] as? String else { throw IosPlatformBridge.error("Invalid OS proxy route") }
          if kind == kCFProxyTypeNone as String { return ["direct": true] }
          guard kind == kCFProxyTypeHTTP as String || kind == kCFProxyTypeHTTPS as String else {
            throw IosPlatformBridge.error("Unsupported OS proxy route")
          }
          return try Self.httpRoute(entry)
        }
        finish(routes.count == 1 ? routes[0] : ["direct": false, "routes": routes])
      } catch { finish(FlutterError(code: "system_proxy_failed", message: "The OS proxy address is invalid or unsupported", details: nil)) }
      return
    }
    guard allowPAC else {
      finish(FlutterError(code: "system_proxy_failed", message: "The OS selected an unsupported proxy route", details: nil)); return
    }
    remainingProxies = Array(proxies.dropFirst())
    var context = CFStreamClientContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: CFProxyAutoConfigurationResultCallback = { info, proxies, error in
      let request = Unmanaged<IosSystemProxyRequest>.fromOpaque(info).takeUnretainedValue()
      guard request.pending != nil else { return }
      guard error == nil, let routes = proxies as? [[String: Any]] else {
        request.finish(FlutterError(code: "system_proxy_failed", message: "The OS could not resolve its proxy configuration", details: nil)); return
      }
      request.select(routes + request.remainingProxies, allowPAC: false)
    }
    if type == kCFProxyTypeAutoConfigurationURL as String,
       let value = proxy[kCFProxyAutoConfigurationURLKey as String] as? URL,
       IosWebSession.webURL(value.absoluteString) != nil {
      source = CFNetworkExecuteProxyAutoConfigurationURL(value as CFURL, url as CFURL, callback, &context)
    } else if type == kCFProxyTypeAutoConfigurationJavaScript as String,
              let script = proxy[kCFProxyAutoConfigurationJavaScriptKey as String] as? String {
      source = CFNetworkExecuteProxyAutoConfigurationScript(script as CFString, url as CFURL, callback, &context)
    }
    guard let source = source else {
      finish(FlutterError(code: "system_proxy_failed", message: "The OS proxy configuration is unsupported", details: nil)); return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    // Retain the request until the callback or native deadline revokes its source.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      if self.pending != nil { self.finish(FlutterError(code: "system_proxy_failed", message: "OS proxy resolution timed out", details: nil)) }
    }
  }

  static func httpRoute(_ proxy: [String: Any]) throws -> [String: Any] {
    guard let host = proxy[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
          let port = proxy[kCFProxyPortNumberKey as String] as? NSNumber, (1...65535).contains(port.intValue),
          proxy[kCFProxyUsernameKey as String] == nil, proxy[kCFProxyPasswordKey as String] == nil,
          !host.contains(where: { $0.isWhitespace || "/@?#;".contains($0) }) else {
      throw IosPlatformBridge.error("Invalid OS proxy route")
    }
    let endpoint = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port.intValue)" : "\(host):\(port.intValue)"
    guard let parsed = URLComponents(string: "http://" + endpoint), parsed.host != nil, parsed.port == port.intValue else {
      throw IosPlatformBridge.error("Invalid OS proxy route")
    }
    return ["direct": false, "proxy": endpoint, "bypass": ""]
  }

  private func finish(_ value: Any) {
    guard let callback = pending else { return }
    pending = nil
    if let source = source { CFRunLoopSourceInvalidate(source) }
    source = nil
    callback(value)
  }
}

/// Bookmarks are private native preferences. Dart stores only an opaque key.
/// iOS document-provider grants can be revoked; an expired grant is an error,
/// allowing the existing Dart export flow to retain its private backup.
enum IosExportDirectory {
  private static let prefix = "ios-bookmark:"
  private static let storagePrefix = "triomi.export-directory."

  static func remember(_ url: URL) throws -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw IosPlatformBridge.error("Select an export folder")
    }
    let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let key = UUID().uuidString
    UserDefaults.standard.set(data, forKey: storagePrefix + key)
    return prefix + key
  }

  static func write(_ args: [String: Any]) throws -> URL {
    guard let token = args["treeUri"] as? String, token.hasPrefix(prefix),
          let name = args["fileName"] as? String, IosPlatformBridge.safeName(name),
          let bookmark = UserDefaults.standard.data(forKey: storagePrefix + String(token.dropFirst(prefix.count))) else {
      throw IosPlatformBridge.error("Export folder grant is missing; select the folder again")
    }
    let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data
    let source = args["sourcePath"] as? String
    guard (bytes != nil) != (source != nil) else { throw IosPlatformBridge.error("Exactly one export input is required") }
    var stale = false
    let directory = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    let scoped = directory.startAccessingSecurityScopedResource()
    defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
    if stale {
      let refreshed = try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(refreshed, forKey: storagePrefix + String(token.dropFirst(prefix.count)))
    }
    var sourceURL: URL?
    if let source = source {
      let url = URL(fileURLWithPath: source).resolvingSymlinksInPath()
      let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
      let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard url.path.hasPrefix(home), metadata.isRegularFile == true, metadata.isSymbolicLink != true else {
        throw IosPlatformBridge.error("Export source must be an application-private regular file")
      }
      sourceURL = url
    }
    var coordinationError: NSError?; var writeError: Error?; var output: URL?
    NSFileCoordinator().coordinate(writingItemAt: directory, options: .forMerging, error: &coordinationError) { folder in
      do {
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw IosPlatformBridge.error("Export folder is unavailable") }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appendingPathComponent(name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
          destination = folder.appendingPathComponent("\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")); suffix += 1
        }
        if let bytes = bytes { try bytes.write(to: destination, options: .withoutOverwriting) }
        else if let sourceURL = sourceURL { try FileManager.default.copyItem(at: sourceURL, to: destination) }
        output = destination
      } catch { writeError = error }
    }
    if let error = coordinationError { throw error }
    if let error = writeError { throw error }
    guard let output = output else { throw IosPlatformBridge.error("The file provider did not return an exported document") }
    return output
  }
}
