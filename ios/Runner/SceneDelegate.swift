import Flutter
import UIKit

// iOS: sin probar en dispositivo (F7). Oculta la vista previa del selector de
// apps (multitarea): al perder el foco se pone una vista opaca con el
// candado; se quita al volver a estar activa.
class SceneDelegate: FlutterSceneDelegate {
  private var privacyCover: UIView?

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    guard privacyCover == nil, let window = self.window else { return }
    let cover = UIView(frame: window.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Mismo color que el fondo de la app (#0B0B0E).
    cover.backgroundColor = UIColor(red: 11.0 / 255.0, green: 11.0 / 255.0, blue: 14.0 / 255.0, alpha: 1.0)
    let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
    lock.tintColor = UIColor(red: 167.0 / 255.0, green: 139.0 / 255.0, blue: 250.0 / 255.0, alpha: 1.0)
    lock.contentMode = .scaleAspectFit
    lock.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(lock)
    NSLayoutConstraint.activate([
      lock.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
      lock.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
      lock.widthAnchor.constraint(equalToConstant: 48),
      lock.heightAnchor.constraint(equalToConstant: 48),
    ])
    window.addSubview(cover)
    privacyCover = cover
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }
}
