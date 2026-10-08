import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeHost: NativeHost?
  private var surfacesChannel: FlutterMethodChannel?
  private var symbolsChannel: FlutterMethodChannel?
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
    let symbols = FlutterMethodChannel(name: "sporra/symbols", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    symbolsChannel = symbols
    symbols.setMethodCallHandler { call, result in
      guard call.method == "render", let args = call.arguments as? [String: Any],
            let name = args["name"] as? String, let size = args["size"] as? Double,
            let scale = args["scale"] as? Double, size.isFinite, scale.isFinite,
            size > 0, size <= 128, scale > 0, scale <= 4 else {
        result(nil); return
      }
      let weight: UIImage.SymbolWeight
      switch args["weight"] as? Int ?? 400 {
      case 700...: weight = .bold
      case 600..<700: weight = .semibold
      case 500..<600: weight = .medium
      default: weight = .regular
      }
      guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight)) else {
        result(nil); return
      }
      let format = UIGraphicsImageRendererFormat()
      format.scale = scale
      format.opaque = false
      let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
        let ratio = min(size / symbol.size.width, size / symbol.size.height)
        let fitted = CGSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
        symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(
          x: (size - fitted.width) / 2, y: (size - fitted.height) / 2, width: fitted.width, height: fitted.height))
      }
      result(image.pngData().map { FlutterStandardTypedData(bytes: $0) })
    }
    let surfaces = FlutterMethodChannel(name: "sporra/surfaces", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    surfacesChannel = surfaces
    surfaces.setMethodCallHandler { call, result in
      guard call.method == "capture", let args = call.arguments as? [String: Any],
            let x = args["x"] as? Double, let y = args["y"] as? Double,
            let width = args["width"] as? Double, let height = args["height"] as? Double,
            let scale = args["scale"] as? Double,
            [x, y, width, height, scale].allSatisfy({ $0.isFinite }),
            width > 0, height > 0, scale > 0, scale <= 4,
            let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
              .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else {
        result(nil); return
      }
      let rect = CGRect(x: x, y: y, width: width, height: height)
      guard window.bounds.contains(rect) else { result(nil); return }
      let format = UIGraphicsImageRendererFormat()
      format.scale = scale
      format.opaque = false
      // UIKit capture includes the native map and its UIVisualEffectView. A
      // Flutter subtree capture omits those pixels and changes the glass tint.
      let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
        context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      result(image.pngData().map { FlutterStandardTypedData(bytes: $0) })
    }


  }
  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    Task { @MainActor in await SyncClient.shared.flush(force: true) }
  }
}
