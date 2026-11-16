import AVFoundation
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
      case "freeSpace":
        // iOS: sin probar en dispositivo. Espacio disponible para datos
        // importantes del usuario (el que iOS puede liberar incluido).
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
          result(NSNumber(value: free))
        } else {
          result(nil)
        }
      case "videoThumbnail":
        // iOS: sin probar en dispositivo. Miniatura de un video LOCAL con
        // AVAssetImageGenerator: lado maximo `size`, JPEG, fotograma central
        // (o el primero si falla). Devuelve nil si no se pudo. Se usa en vez
        // de video_compress (fotograma a resolucion completa, sin respuesta si
        // falla y con posicion -1 por defecto, invalida en iOS).
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path requerido", details: nil))
          return
        }
        let maxSide = (args["size"] as? Int) ?? 256
        DispatchQueue.global(qos: .userInitiated).async {
          let asset = AVURLAsset(url: URL(fileURLWithPath: path))
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.maximumSize = CGSize(width: maxSide, height: maxSide)
          generator.requestedTimeToleranceBefore = CMTime.positiveInfinity
          generator.requestedTimeToleranceAfter = CMTime.positiveInfinity
          let seconds = CMTimeGetSeconds(asset.duration)
          let middle = seconds.isFinite && seconds > 0 ? seconds / 2.0 : 0.0
          var jpeg: Data? = nil
          for t in [middle, 0.0] {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
              jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
              if jpeg != nil { break }
            }
          }
          DispatchQueue.main.async {
            if let data = jpeg {
              result(FlutterStandardTypedData(bytes: data))
            } else {
              result(nil)
            }
          }
        }
      case "monotonic":
        // iOS: sin probar en dispositivo (S-07). mach_continuous_time cuenta
        // desde el arranque e incluye el sueno; no depende de la hora de
        // pared. No hay contador de arranques fiable (kern.boottime cambia
        // con la hora), asi que boot = -1 y el reinicio se detecta porque el
        // valor baja.
        var info = mach_timebase_info_data_t()
        _ = mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let nanos = ticks &* UInt64(info.numer) / UInt64(info.denom)
        result(["boot": -1, "elapsedMs": Int(nanos / 1_000_000)])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
