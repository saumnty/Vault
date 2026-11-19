import AVFoundation
import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers
import Darwin.Mach

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // v2 fase 6: selector de documentos propio (se retiene aqui).
  private let documentPicker = VaultDocumentPicker()

  // iOS: sin probar (v2.2). Titulo de album -> localIdentifier del album que
  // esta app creo en esta ejecucion (solo en memoria).
  private var albumIds: [String: String] = [:]

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerSecurityChannel(messenger: engineBridge.applicationRegistrar.messenger())
    documentPicker.register(messenger: engineBridge.applicationRegistrar.messenger())
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
      case "saveToAlbum":
        // iOS: sin probar en dispositivo (v2.2). Guarda UN archivo ya en
        // claro (la ruta la borra Dart en `finally`) en el album `album`
        // con PhotoKit. Busca el album por titulo entre los de usuario (solo
        // los ve con acceso de lectura); si no lo encuentra, lo CREA en el
        // mismo cambio. Devuelve {"created": Bool}. Con el permiso de solo
        // agregar la busqueda puede no ver el album: Dart detiene el lote si
        // se intenta crear dos veces (evita albumes repetidos).
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let album = args["album"] as? String else {
          result(FlutterError(code: "bad_args", message: "path y album requeridos", details: nil))
          return
        }
        let isVideo = (args["video"] as? Bool) ?? false
        let url = URL(fileURLWithPath: path)
        var existing: PHAssetCollection? = nil
        if let id = self.albumIds[album] {
          existing = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil).firstObject
        }
        if existing == nil {
          let opts = PHFetchOptions()
          opts.predicate = NSPredicate(format: "localizedTitle = %@", album)
          existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: opts).firstObject
        }
        var placeholderId: String? = nil
        let created = (existing == nil)
        PHPhotoLibrary.shared().performChanges({
          let req: PHAssetChangeRequest? = isVideo
            ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
          guard let assetPlaceholder = req?.placeholderForCreatedAsset else { return }
          if let col = existing {
            PHAssetCollectionChangeRequest(for: col)?
              .addAssets([assetPlaceholder] as NSArray)
          } else {
            let create = PHAssetCollectionChangeRequest
              .creationRequestForAssetCollection(withTitle: album)
            placeholderId = create.placeholderForCreatedAssetCollection.localIdentifier
            create.addAssets([assetPlaceholder] as NSArray)
          }
        }) { ok, error in
          DispatchQueue.main.async {
            if ok {
              if let pid = placeholderId { self.albumIds[album] = pid }
              result(["created": created])
            } else {
              result(FlutterError(code: "save_failed", message: "No se pudo guardar", details: nil))
            }
          }
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

// iOS: sin probar (v2 fase 6). Selector de documentos propio, canal
// 'vault/picker'. UIDocumentPickerViewController con asCopy = false: NO copia
// el archivo a tmp/ (a diferencia de file_picker); se lee el original por
// trozos con acceso con alcance de seguridad y se libera al cerrar. Sin logs
// de nombres ni rutas.
final class VaultDocumentPicker: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var docs: [Int: (url: URL, handle: FileHandle)] = [:]
  private var nextHandle = 1
  private let io = DispatchQueue(label: "vault.picker.io")

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "vault/picker", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "pick":
        self.pick(result: result)
      case "read":
        let args = call.arguments as? [String: Any]
        let handle = args?["handle"] as? Int ?? -1
        let length = min(max(args?["length"] as? Int ?? 0, 0), 4 << 20)
        self.io.async {
          guard let doc = self.docs[handle] else {
            DispatchQueue.main.async {
              result(FlutterError(code: "closed", message: "documento cerrado", details: nil))
            }
            return
          }
          var data = Data()
          do {
            while data.count < length {
              let chunk: Data
              if #available(iOS 13.4, *) {
                guard let c = try doc.handle.read(upToCount: length - data.count) else { break }
                chunk = c
              } else {
                chunk = doc.handle.readData(ofLength: length - data.count)
              }
              if chunk.isEmpty { break }
              data.append(chunk)
            }
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "io", message: "lectura fallida", details: nil))
            }
          }
        }
      case "close":
        let args = call.arguments as? [String: Any]
        let handle = args?["handle"] as? Int ?? -1
        self.io.async {
          if let doc = self.docs.removeValue(forKey: handle) {
            if #available(iOS 13.0, *) { try? doc.handle.close() }
            doc.url.stopAccessingSecurityScopedResource()
          }
          DispatchQueue.main.async { result(nil) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func pick(result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "selector ya abierto", details: nil))
      return
    }
    guard let top = topViewController() else {
      result(FlutterError(code: "no_ui", message: "sin ventana", details: nil))
      return
    }
    pending = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: false)
    } else {
      // iOS 13: modo "abrir" (sin copia) con el UTI genérico.
      picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
    }
    picker.allowsMultipleSelection = false
    picker.delegate = self
    top.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?(nil)
    pending = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending else { return }
    pending = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    io.async {
      let scoped = url.startAccessingSecurityScopedResource()
      do {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        let handle = try FileHandle(forReadingFrom: url)
        let id = self.nextHandle
        self.nextHandle += 1
        self.docs[id] = (url: url, handle: handle)
        let reply: [String: Any] = [
          "handle": id,
          "name": values?.name ?? url.lastPathComponent,
          "size": values?.fileSize ?? -1,
        ]
        DispatchQueue.main.async { result(reply) }
      } catch {
        if scoped { url.stopAccessingSecurityScopedResource() }
        DispatchQueue.main.async {
          result(FlutterError(code: "open", message: "no se pudo abrir", details: nil))
        }
      }
    }
  }
}
