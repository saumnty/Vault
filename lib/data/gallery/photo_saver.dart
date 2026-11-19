import 'dart:io';

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/security/auto_lock.dart';

/// Guarda un archivo YA EN CLARO en la fototeca del sistema.
abstract interface class PhotoSaver {
  /// Pide (si hace falta) permiso de solo-agregar. `false` = denegado.
  Future<bool> requestAddPermission();

  /// Abre los ajustes del sistema (permiso denegado).
  Future<void> openSettings();

  Future<void> saveImage(File file, {required String filename});

  Future<void> saveVideo(File file, {required String filename});
}

/// Nombre de álbum seguro a partir del nombre de una carpeta: sin separadores
/// de ruta ni caracteres de control, recortado y nunca vacío.
String albumNameFor(String folderName) {
  final cleaned = folderName
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^\.+'), '');
  final cut = cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  return cut.isEmpty ? 'Kern' : cut;
}

/// Un [PhotoSaver] que además sabe poner la copia en un ÁLBUM con nombre
/// (v2.2). Interfaz aparte para no romper a quien ya implementa [PhotoSaver].
abstract interface class AlbumPhotoSaver implements PhotoSaver {
  /// Devuelve `true` si esta llamada CREÓ el álbum (iOS; en Android la
  /// carpeta de MediaStore se crea sola y siempre devuelve `false`).
  Future<bool> saveImageToAlbum(
    File file, {
    required String filename,
    required String album,
  });

  Future<bool> saveVideoToAlbum(
    File file, {
    required String filename,
    required String album,
  });
}

/// Implementación real sobre `photo_manager` 3.12.0 (ya fijado en el proyecto).
///
/// * iOS: permiso de SOLO AGREGAR (`NSPhotoLibraryAddUsageDescription`), sin
///   pedir lectura de la fototeca. // iOS: sin probar.
/// * Android 10+ (API 29): guardar en MediaStore no requiere permiso. En
///   Android 7-9 (minSdk 24) depende del permiso de almacenamiento; si falla
///   se informa el error (no se pide aquí).
class PhotoManagerPhotoSaver implements AlbumPhotoSaver {
  PhotoManagerPhotoSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vault/security');

  final MethodChannel _channel;

  @override
  Future<bool> requestAddPermission() async {
    if (!Platform.isIOS) return true;
    // iOS: addOnly. El diálogo del sistema pone la app en segundo plano.
    final state = await AutoLockSuspension.instance.run(
      () => PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          iosAccessLevel: IosAccessLevel.addOnly,
        ),
      ),
    );
    return state == PermissionState.authorized ||
        state == PermissionState.limited;
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  Future<void> saveImage(File file, {required String filename}) async {
    await AutoLockSuspension.instance.run(
      () => PhotoManager.editor.saveImageWithPath(file.path, title: filename),
    );
  }

  @override
  Future<void> saveVideo(File file, {required String filename}) async {
    await AutoLockSuspension.instance.run(
      () => PhotoManager.editor.saveVideo(file, title: filename),
    );
  }

  /// Android 10+: `RELATIVE_PATH` = `Pictures/<álbum>` o `Movies/<álbum>`; la
  /// carpeta se crea sola y, si ya existe, se añade a ella. En Android 7-9
  /// el plugin ignora la ruta relativa (queda en la carpeta por defecto).
  /// iOS: canal `vault/security`, método `saveToAlbum` (PhotoKit,
  /// `PHAssetCollectionChangeRequest`). // iOS: sin probar.
  @override
  Future<bool> saveImageToAlbum(
    File file, {
    required String filename,
    required String album,
  }) => _toAlbum(file, filename, album, video: false);

  @override
  Future<bool> saveVideoToAlbum(
    File file, {
    required String filename,
    required String album,
  }) => _toAlbum(file, filename, album, video: true);

  Future<bool> _toAlbum(
    File file,
    String filename,
    String album, {
    required bool video,
  }) async {
    if (Platform.isIOS) {
      final r = await AutoLockSuspension.instance.run(
        () => _channel.invokeMethod<Object?>('saveToAlbum', {
          'path': file.path,
          'album': album,
          'video': video,
          'title': filename,
        }),
      );
      return r is Map && r['created'] == true;
    }
    final rel = video ? 'Movies/$album' : 'Pictures/$album';
    await AutoLockSuspension.instance.run(
      () => video
          ? PhotoManager.editor.saveVideo(
              file,
              title: filename,
              relativePath: rel,
            )
          : PhotoManager.editor.saveImageWithPath(
              file.path,
              title: filename,
              relativePath: rel,
            ),
    );
    return false;
  }
}
