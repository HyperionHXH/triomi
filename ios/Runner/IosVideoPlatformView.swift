import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

/// A process-wide lease prevents a retiring video view from deactivating audio
/// while its replacement already owns the session. Calls are on the main queue.
enum IosVideoAudioSession {
  private static var owners = Set<Int64>()

  static func acquire(_ owner: Int64) throws {
    let session = AVAudioSession.sharedInstance()
    // .playback includes system AirPlay/Bluetooth output. Input-only options
    // such as allowBluetooth/allowAirPlay are invalid for this category.
    try session.setCategory(.playback, mode: .moviePlayback, options: [])
    try session.setActive(true)
    owners.insert(owner)
  }

  static func release(_ owner: Int64) {
    guard owners.remove(owner) != nil, owners.isEmpty else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

final class IosVideoPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger; super.init() }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    IosVideoPlatformView(frame: frame, viewId: viewId, messenger: messenger)
  }
}

/// Inline, background audio and PiP all use this one AVPlayer/AVPlayerLayer.
final class IosVideoPlatformView: NSObject, FlutterPlatformView, AVPictureInPictureControllerDelegate {
  private let container: IosVideoContainer
  private let viewId: Int64
  private let channel: FlutterMethodChannel
  private let playerLayer = AVPlayerLayer()
  private let player = AVPlayer()
  private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: 0, width: 200, height: 40))
  private var item: AVPlayerItem?
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var volumeObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var itemEndToken: NSObjectProtocol?
  private var notificationTokens = [NSObjectProtocol]()
  private var pipController: AVPictureInPictureController?
  private var pipResult: FlutterResult?
  private var pipDeadline: DispatchWorkItem?
  private var pipStarting = false
  private var backgroundAudio = false
  private var desiredPlaying = false
  private var interruptionPaused = false
  private var disposed = false
  private var prepared = false
  private var generation = 0
  private var volumeRequestGeneration = 0
  private var pendingStartMs: Int64 = 0
  private var playbackRate: Float = 1

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
    self.viewId = viewId
    channel = FlutterMethodChannel(name: "triomi/ios-video/\(viewId)", binaryMessenger: messenger)
    container = IosVideoContainer(frame: frame)
    super.init()
    container.owner = self
    container.backgroundColor = .black
    playerLayer.videoGravity = .resizeAspect
    playerLayer.player = player
    container.layer.addSublayer(playerLayer)
    // Keep the system control attached: an unattached/hidden MPVolumeView does
    // not reliably bind to the current output route. Flutter supplies the UI.
    // Only public UIView/UISlider APIs are used, never private class names or
    // the read-only AVAudioSession.outputVolume setter.
    volumeView.showsRouteButton = false
    volumeView.isUserInteractionEnabled = false
    volumeView.accessibilityElementsHidden = true
    container.addSubview(volumeView)
    if AVPictureInPictureController.isPictureInPictureSupported() {
      pipController = AVPictureInPictureController(playerLayer: playerLayer)
      pipController?.delegate = self
      pipController?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "disposed", message: "Video view is disposed", details: nil)); return }
      self.handle(call, result: result)
    }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in self?.emitState() }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.emitState() }
    }
    volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.emitState() }
    }
    installNotifications()
  }

  func view() -> UIView { container }
  fileprivate func layout() { playerLayer.frame = container.bounds }
  private var pipActive: Bool { pipStarting || pipController?.isPictureInPictureActive == true }
  private var canPlay: Bool {
    !interruptionPaused && (UIApplication.shared.applicationState != .background || backgroundAudio || pipActive)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !disposed else { result(FlutterError(code: "disposed", message: "Video view is disposed", details: nil)); return }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "open":
      guard let value = args["url"] as? String, let url = URL(string: value),
            let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme),
            url.user == nil, url.password == nil,
            (scheme == "file" ? url.isFileURL : url.host?.isEmpty == false) else {
        result(FlutterError(code: "invalid_url", message: "Expected a local file or HTTP(S) media URL", details: nil)); return
      }
      let mimeType = args["mimeType"] as? String
      guard mimeType == nil || mimeType == "application/vnd.apple.mpegurl" else {
        result(FlutterError(code: "invalid_mime_type", message: "Unsupported media MIME type", details: nil)); return
      }
      do {
        try IosVideoAudioSession.acquire(viewId)
        open(url, headers: args["headers"] as? [String: String] ?? [:],
             mimeType: mimeType, omitCookies: args["omitCookies"] as? Bool == true,
             start: max(0, (args["startMs"] as? NSNumber)?.int64Value ?? 0))
        result(nil)
      } catch { result(FlutterError(code: "audio_session", message: error.localizedDescription, details: nil)) }
    case "play":
      desiredPlaying = true
      applyPlaybackIntent(); result(nil)
    case "pause":
      desiredPlaying = false
      player.pause(); emitState(); result(nil)
    case "seek":
      let target = max(0, (args["positionMs"] as? NSNumber)?.int64Value ?? 0)
      if !prepared { pendingStartMs = target; result(nil) }
      else { seek(target) { result(nil) } }
    case "setRate":
      guard let rate = (args["rate"] as? NSNumber)?.doubleValue, rate.isFinite, rate > 0, rate <= 4 else {
        result(FlutterError(code: "invalid_rate", message: "Rate must be in (0, 4]", details: nil)); return
      }
      playbackRate = Float(rate)
      if player.rate > 0 { player.rate = playbackRate }
      result(nil)
    case "getMediaVolume": result(mediaVolumeState())
    case "setMediaVolume":
      guard let value = (args["volume"] as? NSNumber)?.doubleValue, value.isFinite, (0...1).contains(value) else {
        result(FlutterError(code: "invalid_volume", message: "Volume must be in [0, 1]", details: nil)); return
      }
      guard let slider = volumeSlider, slider.isEnabled, slider.window != nil else {
        result(mediaVolumeState(error: "media_volume_unavailable")); return
      }
      volumeRequestGeneration += 1
      let request = volumeRequestGeneration
      slider.setValue(Float(value), animated: false)
      slider.sendActions(for: [.valueChanged, .touchUpInside])
      // The route applies volume asynchronously. Return its actual readback,
      // not the requested slider position or an AVPlayer-only gain.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self = self, !self.disposed else {
          result(FlutterError(code: "disposed", message: "Video view is disposed", details: nil)); return
        }
        let actual = AVAudioSession.sharedInstance().outputVolume
        // An earlier drag sample may already have been superseded by a newer
        // requested level; only the latest sample can report a rejected write.
        let notApplied = request == self.volumeRequestGeneration && abs(Double(actual) - value) > 0.04
        result(self.mediaVolumeState(error: notApplied ? "media_volume_not_applied" : nil))
        self.emitState()
      }
    case "setAspectRatio":
      if let ratio = (args["ratio"] as? NSNumber)?.doubleValue, ratio.isFinite, ratio > 0 {
        playerLayer.videoGravity = .resize
      } else { playerLayer.videoGravity = .resizeAspect }
      result(nil)
    case "setBackgroundAudio":
      backgroundAudio = args["enabled"] as? Bool == true
      updateLayer(); applyPlaybackIntent(); result(nil)
    case "subtitleTracks": result(subtitleTracks())
    case "selectSubtitle":
      if let group = item?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
        let index = (args["id"] as? String).flatMap(Int.init)
        item?.select(index.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }, in: group)
      }
      result(nil)
    case "enterPip": enterPip(result)
    case "dispose": dispose(); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ url: URL, headers: [String: String], mimeType: String?, omitCookies: Bool, start: Int64) {
    generation += 1
    let currentGeneration = generation
    statusObservation?.invalidate()
    if let token = itemEndToken { NotificationCenter.default.removeObserver(token) }
    prepared = false; pendingStartMs = start; desiredPlaying = true
    player.pause()
    // This string option matches Flutter's AVFoundation video plugin convention;
    // Apple does not expose a public Swift HTTP-header constant. Headers remain
    // scoped by the resolved source URL, never passed to external applications.
    var requestHeaders = headers
    var options = [String: Any]()
    if omitCookies {
      requestHeaders = requestHeaders.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
      // Explicitly override cookie injection without touching shared storage.
      requestHeaders["Cookie"] = ""
      options[AVURLAssetHTTPCookiesKey] = [HTTPCookie]()
    }
    if !requestHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = requestHeaders }
    if #available(iOS 17.0, *), let mimeType = mimeType {
      options[AVURLAssetOverrideMIMETypeKey] = mimeType
    }
    let next = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
    // AVFoundation owns the memory budget; request the same long lookahead as
    // desktop without pretending its public API offers a strict byte cap.
    next.preferredForwardBufferDuration = 2_147_483
    item = next
    player.replaceCurrentItem(with: next)
    updateLayer()
    statusObservation = next.observe(\.status, options: [.initial, .new]) { [weak self, weak next] _, _ in
      DispatchQueue.main.async {
        guard let self = self, let next = next, !self.disposed,
              self.generation == currentGeneration, self.item === next else { return }
        switch next.status {
        case .readyToPlay:
          guard !self.prepared else { return }
          self.prepared = true
          self.seek(self.pendingStartMs) { [weak self] in
            guard let self = self, !self.disposed, self.generation == currentGeneration else { return }
            self.applyPlaybackIntent()
            self.channel.invokeMethod("prepared", arguments: self.state())
          }
        case .failed:
          self.desiredPlaying = false
          self.channel.invokeMethod("error", arguments: ["message": next.error?.localizedDescription ?? "Media could not be prepared"])
        default: break
        }
      }
    }
    itemEndToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: next, queue: .main) { [weak self] _ in
      guard let self = self, !self.disposed, self.generation == currentGeneration else { return }
      self.desiredPlaying = false
      self.channel.invokeMethod("completed", arguments: self.state())
    }
  }

  private func seek(_ milliseconds: Int64, completion: @escaping () -> Void) {
    let currentGeneration = generation
    var seconds = Double(milliseconds) / 1000
    if let duration = item?.duration.seconds, duration.isFinite, duration > 0 { seconds = min(seconds, max(0, duration - 0.01)) }
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        if let self = self, !self.disposed, self.generation == currentGeneration { self.emitState() }
        completion()
      }
    }
  }

  private func applyPlaybackIntent() {
    if prepared && desiredPlaying && canPlay { player.playImmediately(atRate: playbackRate) }
    else { player.pause() }
    emitState()
  }

  private func updateLayer() {
    let visible = UIApplication.shared.applicationState != .background || pipActive
    playerLayer.player = visible ? player : nil
  }

  private func subtitleTracks() -> [[String: Any]] {
    guard let group = item?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return [] }
    return group.options.enumerated().map { index, option in
      ["id": String(index), "title": option.displayName, "language": option.locale?.languageCode ?? ""]
    }
  }

  private func enterPip(_ result: @escaping FlutterResult) {
    guard let pip = pipController, pip.isPictureInPicturePossible else { result(false); return }
    if pip.isPictureInPictureActive { result(true); return }
    guard pipResult == nil else { result(false); return }
    pipStarting = true; pipResult = result
    updateLayer()
    let deadline = DispatchWorkItem { [weak self] in self?.finishPipRequest(false) }
    pipDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    pip.startPictureInPicture()
  }

  private func finishPipRequest(_ success: Bool) {
    pipDeadline?.cancel(); pipDeadline = nil
    let callback = pipResult; pipResult = nil; pipStarting = false
    updateLayer(); applyPlaybackIntent()
    callback?(success)
  }

  private func installNotifications() {
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
      notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.updateLayer(); self?.applyPlaybackIntent()
      })
    }
    notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
      if type == AVAudioSession.InterruptionType.began.rawValue { self.interruptionPaused = true }
      else {
        self.interruptionPaused = false
        let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        if !options.contains(.shouldResume) { self.desiredPlaying = false }
        if self.desiredPlaying { try? IosVideoAudioSession.acquire(self.viewId) }
      }
      self.applyPlaybackIntent()
    })
    notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
      self.desiredPlaying = false; self.applyPlaybackIntent()
    })
  }
  private var volumeSlider: UISlider? {
    volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
  }

  private func mediaVolumeState(error: String? = nil) -> [String: Any] {
    let slider = volumeSlider
    var state: [String: Any] = [
      "mediaVolume": Double(AVAudioSession.sharedInstance().outputVolume),
      "mediaVolumeCanSet": slider?.isEnabled == true && slider?.window != nil
    ]
    if let error = error { state["mediaVolumeError"] = error }
    return state
  }


  private func state() -> [String: Any] {
    let position = player.currentTime()
    let seconds = position.seconds
    var buffered = position
    if seconds.isFinite, let item = item {
      for value in item.loadedTimeRanges {
        let range = value.timeRangeValue
        let end = CMTimeRangeGetEnd(range)
        if range.start.seconds <= seconds + 0.25, end.seconds >= seconds,
           end.seconds.isFinite, end > buffered {
          buffered = end
        }
      }
    }
    var result = mediaVolumeState()
    result["positionMs"] = position.triomiMilliseconds
    result["durationMs"] = item?.duration.triomiMilliseconds ?? 0
    result["bufferedPositionMs"] = buffered.triomiMilliseconds
    result["playing"] = player.rate > 0
    return result
  }
  private func emitState() { if !disposed { channel.invokeMethod("state", arguments: state()) } }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    finishPipRequest(true); channel.invokeMethod("pip", arguments: ["enabled": true])
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    finishPipRequest(false); channel.invokeMethod("pip", arguments: ["enabled": false])
  }
  func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    finishPipRequest(false)
  }
  func pictureInPictureController(_ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    updateLayer(); completionHandler(!disposed && container.window != nil)
  }

  private func dispose() {
    guard !disposed else { return }
    disposed = true; generation += 1
    pipDeadline?.cancel(); pipResult?(false); pipResult = nil
    pipController?.delegate = nil; pipController?.stopPictureInPicture(); pipController = nil
    statusObservation?.invalidate(); timeControlObservation?.invalidate(); volumeObservation?.invalidate()
    if let token = timeObserver { player.removeTimeObserver(token); timeObserver = nil }
    if let token = itemEndToken { NotificationCenter.default.removeObserver(token) }
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    notificationTokens.removeAll()
    player.pause(); player.replaceCurrentItem(with: nil); item = nil; playerLayer.player = nil
    channel.setMethodCallHandler(nil)
    IosVideoAudioSession.release(viewId)
  }
  deinit { dispose() }
}

private final class IosVideoContainer: UIView {
  weak var owner: IosVideoPlatformView?
  override func layoutSubviews() { super.layoutSubviews(); owner?.layout() }
}

private extension CMTime {
  var triomiMilliseconds: Int64 {
    guard isNumeric, seconds.isFinite else { return 0 }
    return Int64(min(Double(Int64.max - 1024), max(0, seconds * 1000)))
  }
}
