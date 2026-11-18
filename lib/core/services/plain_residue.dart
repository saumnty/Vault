import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';

/// Restos EN CLARO que dejan plugins de terceros fuera de `tmp_plain/`
/// (revisión de seguridad S-02).
///
/// * `file_picker` (Android) copia CADA archivo elegido a
///   `<cacheDir>/file_picker/<ms>/<nombre original>` y no lo borra nunca; en
///   iOS el selector entrega una copia en el `tmp/` del contenedor.
/// * La importación de la galería usa `vault_cache/import_tmp/` (se borra al
///   terminar el lote, pero no si el proceso muere a mitad).
///
/// [deletePickerCopy] borra la copia tras cifrarla (éxito o fallo) y
/// [sweepAtStartup] barre lo que haya quedado de un cierre abrupto.
class PlainResidue {
  PlainResidue._();

  /// Carpetas donde `file_picker` deja sus copias en este dispositivo.
  /// Android: `<cacheDir>/file_picker`. iOS: `tmp/` del contenedor
  /// (iOS: sin probar en dispositivo).
  static Future<List<Directory>> pickerCopyRoots() async {
    if (Platform.isAndroid) {
      final cache = await getTemporaryDirectory(); // = Context.getCacheDir()
      return [Directory(p.join(cache.path, 'file_picker'))];
    }
    if (Platform.isIOS) return [Directory.systemTemp];
    return const [];
  }

  /// `true` si [path] está DENTRO de alguna de [roots] (nunca la raíz misma).
  /// Es la salvaguarda que impide borrar un archivo del usuario: solo se
  /// borran copias privadas del plugin.
  static bool isWithinRoots(String path, List<Directory> roots) {
    final target = p.normalize(p.absolute(path));
    for (final r in roots) {
      final root = p.normalize(p.absolute(r.path));
      if (p.isWithin(root, target)) return true;
    }
    return false;
  }

  /// Borra la copia [path] que entregó el selector si está dentro de
  /// [roots], y su carpeta contenedora (`<ms>/`) si queda vacía y no es una
  /// raíz. Devuelve `true` si se borró algo. Nunca lanza.
  static Future<bool> deletePickerCopy(
    String path,
    List<Directory> roots,
  ) async {
    if (!isWithinRoots(path, roots)) return false;
    var deleted = false;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        deleted = true;
      }
      final parent = f.parent;
      final isRoot = roots.any(
        (r) => p.equals(p.normalize(r.path), p.normalize(parent.path)),
      );
      if (!isRoot &&
          isWithinRoots(parent.path, roots) &&
          await parent.exists() &&
          await parent.list().isEmpty) {
        await parent.delete();
      }
    } on FileSystemException {
      // Mejor esfuerzo: se barrerá al arrancar.
    }
    return deleted;
  }

  /// Borra el contenido completo de [dirs] (no las carpetas). Devuelve cuántas
  /// entradas se borraron. Nunca lanza.
  static Future<int> sweepDirectories(List<Directory> dirs) async {
    var n = 0;
    for (final d in dirs) {
      try {
        if (!await d.exists()) continue;
        await for (final e in d.list()) {
          try {
            await e.delete(recursive: true);
            n++;
          } on FileSystemException {
            // en uso
          }
        }
      } on FileSystemException {
        // sin acceso
      }
    }
    return n;
  }

  /// Carpeta de temporales de la importación de la galería.
  static Directory get galleryImportTmp =>
      Directory(p.join(AppPaths.cacheDir.path, 'import_tmp'));

  /// Al arrancar (antes de cualquier importación): copias del selector de
  /// Android y temporales de la importación de la galería. En iOS NO se barre
  /// `tmp/` entero (lo comparten otros plugins); allí se borra cada copia al
  /// importar.
  static Future<int> sweepAtStartup() async {
    final dirs = <Directory>[];
    if (Platform.isAndroid) dirs.addAll(await pickerCopyRoots());
    if (AppPaths.isInitialized) {
      dirs.add(galleryImportTmp);
      // Fase 8 (G5): también la de la bóveda secundaria (si no existe, no se
      // crea: `sweepDirectories` salta las carpetas ausentes).
      dirs.add(VaultPaths.secondary.importTmpDir);
    }
    return sweepDirectories(dirs);
  }
}
