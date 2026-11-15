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
class PlainTempManager {
  PlainTempManager({Directory Function()? dirProvider})
    : _dirProvider = dirProvider ?? (() => AppPaths.tmpPlainDir);

  /// Instancia de la app.
  static final PlainTempManager instance = PlainTempManager();

  final Directory Function() _dirProvider;
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
    _sweepSync();
  }

  /// Barre la carpeta entera (arranque / desbloqueo). Devuelve cuántos
  /// archivos se borraron.
  Future<int> sweep() async {
    final dir = directory;
    var n = 0;
    if (!await dir.exists()) return 0;
    await for (final e in dir.list()) {
      if (_active.contains(e.path)) continue; // en uso por un visor vivo
      try {
        await e.delete(recursive: true);
        n++;
      } on FileSystemException {
        // en uso: se reintentará
      }
    }
    return n;
  }

  void _sweepSync() {
    final dir = directory;
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
