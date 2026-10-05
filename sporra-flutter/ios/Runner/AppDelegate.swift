import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeHost: NativeHost?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    MainActor.assumeIsolated {
      LocationLogger.shared.resume()
      HealthSync.shared.apply()
      PhotoSync.shared.resume()
    }
    // UIScene creates the implicit engine when a foreground scene connects.
    // A location-only wake resumes Swift services without constructing a scene.
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let host = NativeHost()
    nativeHost = host
    SporraNativeSetup.setUp(binaryMessenger: engineBridge.applicationRegistrar.messenger(), api: host)
  }
  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    Task { @MainActor in await SyncClient.shared.flush(force: true) }
  }
}
