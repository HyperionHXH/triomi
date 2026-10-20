import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var platformBridge: IosPlatformBridge?
  private var jsRuntime: IosJsRuntime?
  private var backupArtifacts: IosBackupArtifactGuard?
  private var videoFactory: IosVideoPlatformViewFactory?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    try? IosBackupArtifactGuard.configureStorage()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.applicationRegistrar
    let messenger = registrar.messenger()
    platformBridge = IosPlatformBridge(messenger: messenger)
    jsRuntime = IosJsRuntime(messenger: messenger)
    backupArtifacts = IosBackupArtifactGuard(messenger: messenger)
    let factory = IosVideoPlatformViewFactory(messenger: messenger)
    videoFactory = factory
    registrar.register(factory, withId: "triomi/ios-video")
  }
}
