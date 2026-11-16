import Flutter
import UIKit
import Darwin.Mach

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerSecurityChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }

  // iOS: sin probar en dispositivo (F7). Canal 'vault/security': el metodo
  // 'excludeFromBackup' marca las rutas con NSURLIsExcludedFromBackupKey para
  // que no viajen en el respaldo de iCloud/iTunes. 'setSecure' es solo de
  // Android; aqui se acepta y se ignora.
  private func registerSecurityChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "vault/security", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "excludeFromBackup":
        guard let args = call.arguments as? [String: Any],
              let paths = args["paths"] as? [String] else {
          result(FlutterError(code: "bad_args", message: "paths requerido", details: nil))
          return
        }
        var failed = 0
        for path in paths {
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          do {
            try url.setResourceValues(values)
          } catch {
            failed += 1
          }
        }
        if failed > 0 {
          result(FlutterError(code: "exclude_failed", message: "\(failed) ruta(s) sin excluir", details: nil))
        } else {
          result(nil)
        }
      case "setSecure":
        result(nil)
      case "monotonic":
        // iOS: sin probar en dispositivo (S-07). mach_continuous_time cuenta
        // desde el arranque e incluye el sueno; no depende de la hora de
        // pared. No hay contador de arranques fiable (kern.boottime cambia
        // con la hora), asi que boot = -1 y el reinicio se detecta porque el
        // valor baja.
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let nanos = ticks &* UInt64(info.numer) / UInt64(info.denom)
        result(["boot": -1, "elapsedMs": Int(nanos / 1_000_000)])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
