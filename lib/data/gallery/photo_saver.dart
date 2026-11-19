import 'dart:io';

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

/// Implementación real sobre `photo_manager` 3.12.0 (ya fijado en el proyecto).
///
/// * iOS: permiso de SOLO AGREGAR (`NSPhotoLibraryAddUsageDescription`), sin
///   pedir lectura de la fototeca. // iOS: sin probar.
/// * Android 10+ (API 29): guardar en MediaStore no requiere permiso. En
///   Android 7-9 (minSdk 24) depende del permiso de almacenamiento; si falla
///   se informa el error (no se pide aquí).
class PhotoManagerPhotoSaver implements PhotoSaver {
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
}
