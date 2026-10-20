import Darwin
import Flutter
import Foundation

/// flock is descriptor-scoped, unlike Dart/POSIX fcntl's process-scoped locks.
/// One registry covers all Flutter engines; the OS lock also excludes processes.
final class IosBackupArtifactGuard {
  private let owner = UUID().uuidString
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "triomi/backup-artifacts", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "acquire":
        let args = call.arguments as? [String: Any] ?? [:]
        result(IosBackupArtifactRegistry.acquire(owner: self.owner, cleanup: args["cleanup"] as? Bool == true))
      case "release":
        if let token = call.arguments as? String { IosBackupArtifactRegistry.release(token: token, owner: self.owner) }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { IosBackupArtifactRegistry.releaseOwner(owner) }

  static func configureStorage() throws -> [String: Any] {
    let files = FileManager.default
    let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
    let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
    for directory in [documents, support] {
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      var mutable = directory; try mutable.setResourceValues(values)
      // Excluding the directory excludes its entire subtree, including future
      // downloads. Do not walk every cached comic page on each cold launch.
    }
    let d = (try documents.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true
    let s = (try support.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true
    return ["documentsPath": documents.path, "supportPath": support.path, "documentsExcluded": d, "supportExcluded": s]
  }

}

enum IosBackupArtifactRegistry {
  private struct Lease {
    let owner: String
    let cleanup: Bool
  }
  private static let mutex = NSLock()
  private static var leases = [String: Lease]()
  private static var descriptor: Int32 = -1

  static func acquire(owner: String, cleanup: Bool) -> String? {
    mutex.lock(); defer { mutex.unlock() }
    if !leases.isEmpty {
      guard !cleanup, !leases.values.contains(where: { $0.cleanup }) else { return nil }
      let token = UUID().uuidString
      leases[token] = Lease(owner: owner, cleanup: false)
      return token
    }
    do {
      let files = FileManager.default
      let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
      let root = support.appendingPathComponent("triomi-backup-control", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      let metadata = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard metadata.isDirectory == true, metadata.isSymbolicLink != true,
            root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { return nil }
      let path = root.appendingPathComponent("artifacts.lock").path
      let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { return nil }
      var status = stat()
      guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
            flock(fd, (cleanup ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
        close(fd); return nil
      }
      descriptor = fd
      let token = UUID().uuidString
      leases[token] = Lease(owner: owner, cleanup: cleanup)
      return token
    } catch { return nil }
  }

  static func release(token: String, owner: String) {
    mutex.lock(); defer { mutex.unlock() }
    guard leases[token]?.owner == owner else { return }
    leases.removeValue(forKey: token)
    closeIfUnused()
  }

  static func releaseOwner(_ owner: String) {
    mutex.lock(); defer { mutex.unlock() }
    leases = leases.filter { $0.value.owner != owner }
    closeIfUnused()
  }

  private static func closeIfUnused() {
    if leases.isEmpty, descriptor >= 0 {
      flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
    }
  }
}
