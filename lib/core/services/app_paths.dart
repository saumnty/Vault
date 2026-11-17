import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Punto único de resolución de rutas de la app.
///
/// En la BD solo se guardan rutas RELATIVAS al directorio de documentos de la
/// app (p. ej. `vault/<id>.vault`), porque en iOS la ruta absoluta del
/// contenedor cambia entre instalaciones/actualizaciones. Las rutas relativas
/// siempre usan `/` como separador, también en Windows.
class AppPaths {
  AppPaths._();

  static const String vaultDirName = 'vault';
  static const String thumbsDirName = 'thumbs';
  static const String cacheDirName = 'vault_cache';
  static const String dbDirName = 'db';

  /// Temporales DESCIFRADOS (video completo-primero) dentro de la caché. Se
  /// borran al cerrar el visor, al bloquear y se barren al arrancar/desbloquear.
  static const String tmpPlainDirName = 'tmp_plain';

  static Directory? _base;

  /// Inicializa con el directorio de documentos de la app, o con [baseDir]
  /// (inyectable para pruebas). Idempotente: si ya está inicializado y no se
  /// pasa [baseDir], solo se aseguran los subdirectorios.
  static Future<void> init({Directory? baseDir}) async {
    if (baseDir != null) {
      _base = baseDir;
    } else {
      _base ??= await getApplicationDocumentsDirectory();
    }
    for (final d in [vaultDir, thumbsDir, cacheDir, dbDir]) {
      if (!d.existsSync()) d.createSync(recursive: true);
    }
  }

  /// Solo pruebas: olvida el directorio base.
  static void resetForTesting() => _base = null;

  static bool get isInitialized => _base != null;

  static Directory get baseDir {
    final b = _base;
    if (b == null) {
      throw StateError('AppPaths.init() no fue llamado');
    }
    return b;
  }

  static Directory get vaultDir =>
      Directory(p.join(baseDir.path, vaultDirName));
  static Directory get thumbsDir =>
      Directory(p.join(baseDir.path, thumbsDirName));
  static Directory get cacheDir =>
      Directory(p.join(baseDir.path, cacheDirName));
  static Directory get tmpPlainDir =>
      Directory(p.join(cacheDir.path, tmpPlainDirName));
  static Directory get dbDir => Directory(p.join(baseDir.path, dbDirName));

  /// Mayor generación de llave admitida en nombres de archivo (D60).
  static const int maxKeyGen = 9999;

  /// Sufijo de generación de llave en nombres de archivo (D60): vacío para la
  /// generación 1 (los nombres de siempre) y `.kN` para N ≥ 2. Lanza
  /// [ArgumentError] fuera de 1..[maxKeyGen].
  static String keyGenSuffix(int gen) {
    if (gen < 1 || gen > maxKeyGen) {
      throw ArgumentError.value(
        gen,
        'gen',
        'Generación de llave fuera de rango',
      );
    }
    return gen == 1 ? '' : '.k$gen';
  }

  /// Ruta relativa del archivo cifrado de un item: `vault/<id>.vault` (gen 1)
  /// o `vault/<id>.kN.vault` (gen N ≥ 2).
  static String vaultRelativePath(String itemId, {int gen = 1}) =>
      '$vaultDirName/$itemId${keyGenSuffix(gen)}.vault';

  /// Ruta relativa de la miniatura cifrada de un item: `thumbs/<id>.thumb`
  /// (gen 1) o `thumbs/<id>.kN.thumb` (gen N ≥ 2).
  static String thumbRelativePath(String itemId, {int gen = 1}) =>
      '$thumbsDirName/$itemId${keyGenSuffix(gen)}.thumb';

  /// `true` si [path] es absoluta (POSIX, Windows con unidad o UNC).
  static bool isAbsolutePath(String path) =>
      path.startsWith('/') ||
      path.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path) ||
      p.isAbsolute(path);

  /// UUID v4 en minúsculas (los ids de items se generan con `Uuid().v4()`).
  static final RegExp _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// Sufijo opcional de generación `.kN` con N en 2..9999 sin ceros a la
  /// izquierda (D60). La generación 1 no lleva sufijo.
  static const String keyGenSuffixPattern =
      r'(?:\.k(?:[2-9]|[1-9][0-9]{1,3}))?';

  static final RegExp _itemFilePath = RegExp(
    r'^(?:vault/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
    '$keyGenSuffixPattern'
    r'\.vault'
    r'|thumbs/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
    '$keyGenSuffixPattern'
    r'\.thumb)$',
  );

  /// Solo pruebas: acepta ids no UUID (`i1`, `a`…) en las rutas de items. Las
  /// pruebas de S-15 lo dejan en `false`.
  @visibleForTesting
  static bool allowNonUuidIdsForTesting = false;

  /// `true` si [id] es un UUID v4 en minúsculas.
  static bool isValidItemId(String id) =>
      _uuidV4.hasMatch(id) ||
      (allowNonUuidIdsForTesting &&
          RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id));

  /// S-15: valida la ruta relativa de un archivo de item. Solo se acepta
  /// exactamente `vault/<uuid>[.kN].vault` o `thumbs/<uuid>[.kN].thumb` (UUID
  /// v4 en minúsculas, generación opcional N ≥ 2 (D60), sin subcarpetas, `..`,
  /// mayúsculas ni barras invertidas).
  /// Devuelve la ruta tal cual. Las rutas de otros recursos (caché, tmp, BD)
  /// no pasan por aquí: se construyen con [cacheDir], [tmpPlainDir], [dbDir].
  static String validateRelative(String path) {
    // Primero las comprobaciones genéricas (mensajes claros: vacía, absoluta,
    // sale de la base).
    validateGenericRelative(path);
    if (_itemFilePath.hasMatch(path)) return path;
    if (allowNonUuidIdsForTesting &&
        RegExp(
          r'^(?:vault/[^/\\]+\.vault|thumbs/[^/\\]+\.thumb)$',
        ).hasMatch(path) &&
        !path.contains('..')) {
      return path;
    }
    throw ArgumentError.value(
      path,
      'path',
      'Se esperaba vault/<uuid>.vault o thumbs/<uuid>.thumb',
    );
  }

  /// Valida y normaliza una ruta relativa cualquiera dentro de la base.
  /// Rechaza absolutas, vacías y las que salgan del directorio base (`..`).
  /// Devuelve la ruta con `/`. NO sirve para archivos de items (S-15).
  static String validateGenericRelative(String path) {
    if (path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'La ruta está vacía');
    }
    if (isAbsolutePath(path)) {
      throw ArgumentError.value(
        path,
        'path',
        'Se esperaba una ruta relativa, no absoluta',
      );
    }
    final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
    if (normalized == '..' ||
        normalized.startsWith('../') ||
        normalized == '.') {
      throw ArgumentError.value(
        path,
        'path',
        'La ruta sale del directorio base',
      );
    }
    return normalized;
  }

  /// Ruta absoluta de una ruta relativa guardada en la BD.
  static String resolvePath(String relativePath) {
    final rel = validateRelative(relativePath);
    return p.joinAll([baseDir.path, ...rel.split('/')]);
  }

  /// [File] de una ruta relativa guardada en la BD.
  static File resolve(String relativePath) => File(resolvePath(relativePath));

  /// Convierte una ruta absoluta dentro del directorio base en relativa (`/`).
  /// Lanza [ArgumentError] si [absolutePath] está fuera del directorio base.
  static String relative(String absolutePath) {
    final base = p.normalize(baseDir.path);
    final abs = p.normalize(absolutePath);
    if (!p.isWithin(base, abs)) {
      throw ArgumentError.value(
        absolutePath,
        'absolutePath',
        'Está fuera del directorio de la app',
      );
    }
    return p.split(p.relative(abs, from: base)).join('/');
  }
}
