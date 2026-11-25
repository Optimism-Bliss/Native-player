import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // app opened by a torboxstrm:// link
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts { AppLinks.deliver(context.url) }
  }

  // link opened while the app runs
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts { AppLinks.deliver(context.url) }
  }
}
