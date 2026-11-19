import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// Gestiona los temporales DESCIFRADOS (video completo-primero) en
/// `AppPaths.tmpPlainDir`.
///
/// Garantías (ver pruebas en `test/plain_temp_manager_test.dart`):
/// * cada temporal se borra al cerrar el visor ([release]);
/// * al bloquear la app se borran todos, de forma SÍNCRONA ([purgeSync],
///   enganchado a `VaultSession.addOnClear`);
/// * al arrancar y al desbloquear se barre toda la carpeta ([sweep]) por si
///   hubo un cierre abrupto.
/// Las imágenes nunca pasan por aquí: se descifran en memoria.
///
/// Fase 8 (G5): la instancia de la app barre además, al bloquear y al
/// arrancar ([sweepAll]), la carpeta `tmp_plain/` de la bóveda secundaria si
/// existe (nunca la crea).
class PlainTempManager {
  PlainTempManager({
    Directory Function()? dirProvider,
    List<Directory> Function()? otherDirsProvider,
  }) : _dirProvider = dirProvider ?? (() => AppPaths.tmpPlainDir),
       _otherDirs = otherDirsProvider ?? (() => const []);

  /// Instancia de la app (bóveda principal; al bloquear barre también la
  /// carpeta de la secundaria).
  static final PlainTempManager instance = PlainTempManager(
    otherDirsProvider: allVaultTmpPlainDirs,
  );

  /// `tmp_plain/` de TODAS las bóvedas (vacía si `AppPaths` no se inicializó).
  static List<Directory> allVaultTmpPlainDirs() => AppPaths.isInitialized
      ? [for (final v in VaultPaths.all) v.tmpPlainDir]
      : const [];

  final Directory Function() _dirProvider;
  final List<Directory> Function() _otherDirs;
  final Set<String> _active = {};
  int _counter = 0;

  Directory get directory => _dirProvider();

  /// Número de temporales vivos registrados.
  int get activeCount => _active.length;

  /// Crea la ruta (sin crear el archivo) de un temporal nuevo. [extension]
  /// con punto (p. ej. `.mp4`) ayuda a ExoPlayer/AVPlayer a reconocer el tipo.
  File newTempFile({String extension = ''}) {
    final dir = directory;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name =
        'p${DateTime.now().microsecondsSinceEpoch}_${_counter++}$extension';
    final file = File(p.join(dir.path, name));
    _active.add(file.path);
    return file;
  }

  /// Borra el temporal (idempotente, tolera que no exista o esté en uso).
  Future<void> release(File file) async {
    _active.remove(file.path);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Se barrerá al desbloquear/arrancar.
    }
  }

  /// Borrado síncrono de todo lo registrado y de la carpeta (bloqueo).
  void purgeSync() {
    _active.clear();
    final own = directory;
    _sweepDirSync(own);
    for (final d in _otherDirs()) {
      if (p.equals(p.normalize(d.path), p.normalize(own.path))) continue;
      _sweepDirSync(d);
    }
  }

  /// Arranque: barre su carpeta y las de las demás bóvedas (sin crearlas).
  /// Devuelve cuántas entradas se borraron.
  Future<int> sweepAll() async {
    var n = await sweep();
    final own = p.normalize(directory.path);
    for (final d in _otherDirs()) {
      if (p.equals(p.normalize(d.path), own)) continue;
      n += await _sweepDir(d, const {});
    }
    return n;
  }

  /// Barre la carpeta entera (arranque / desbloqueo). Devuelve cuántos
  /// archivos se borraron.
  Future<int> sweep() => _sweepDir(directory, _active);

  static Future<int> _sweepDir(Directory dir, Set<String> keep) async {
    var n = 0;
    if (!await dir.exists()) return 0;
    await for (final e in dir.list()) {
      if (keep.contains(e.path)) continue; // en uso por un visor vivo
      try {
        await e.delete(recursive: true);
        n++;
      } on FileSystemException {
        // en uso: se reintentará
      }
    }
    return n;
  }

  static void _sweepDirSync(Directory dir) {
    if (!dir.existsSync()) return;
    for (final e in dir.listSync()) {
      try {
        e.deleteSync(recursive: true);
      } on FileSystemException {
        // en uso
      }
    }
  }
}
