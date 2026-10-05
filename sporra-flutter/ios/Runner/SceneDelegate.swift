import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    Task { @MainActor in await SyncClient.shared.flush(force: true) }
  }
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    MainActor.assumeIsolated {
      LocationLogger.shared.resume()
      PhotoSync.shared.resume()
    }
  }
}
