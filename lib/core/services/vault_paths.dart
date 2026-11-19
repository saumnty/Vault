import 'dart:io';

import 'package:path/path.dart' as p;

import '../session/vault_slot.dart';
import 'app_paths.dart';

/// Rutas de UNA bóveda (D67, `docs/DISENO_SENUELO.md` §2.2).
///
/// No hay raíz global mutable: cada bóveda tiene su resolutor fijo.
/// * [primary]: raíz = el directorio de documentos de la app (exactamente la
///   de siempre; [AppPaths] delega aquí).
/// * [secondary]: raíz = `Documents/alt`. Solo la usan, por inyección, los
///   servicios de la bóveda secundaria.
///
/// La raíz de documentos la sigue fijando [AppPaths.init]. Nada aquí CREA
/// directorios salvo [ensureDirs] (la principal los crea `AppPaths.init`; la
/// secundaria solo al crearla): un arranque sin bóveda secundaria nunca
/// escribe `alt/` (G1, M2).
///
/// Las rutas relativas guardadas en la BD tienen el mismo formato en las dos
/// bóvedas (`vault/<uuid>.vault`, S-15) y cada una las resuelve contra SU raíz.
class VaultPaths {
  const VaultPaths._(this.slot);

  static const VaultPaths primary = VaultPaths._(VaultSlot.primary);
  static const VaultPaths secondary = VaultPaths._(VaultSlot.secondary);

  /// Todas las bóvedas (para los barridos de temporales).
  static const List<VaultPaths> all = [primary, secondary];

  static VaultPaths of(VaultSlot slot) => switch (slot) {
    VaultSlot.primary => primary,
    VaultSlot.secondary => secondary,
  };

  /// Nombre (neutro) del directorio de la bóveda secundaria.
  static const String secondaryRootName = 'alt';

  /// Nombre del archivo de la BD (igual en las dos bóvedas).
  static const String dbFileName = 'vault_secure.db';

  static const String importTmpDirName = 'import_tmp';

  final VaultSlot slot;

  /// Raíz de la bóveda. Lanza [StateError] si [AppPaths.init] no se llamó.
  Directory get root => switch (slot) {
    VaultSlot.primary => AppPaths.baseDir,
    VaultSlot.secondary => Directory(
      p.join(AppPaths.baseDir.path, secondaryRootName),
    ),
  };

  /// `true` si la raíz existe en disco (la principal, siempre tras `init`).
  bool get exists => root.existsSync();

  Directory get vaultDir => Directory(p.join(root.path, AppPaths.vaultDirName));
  Directory get thumbsDir =>
      Directory(p.join(root.path, AppPaths.thumbsDirName));
  Directory get cacheDir => Directory(p.join(root.path, AppPaths.cacheDirName));
  Directory get tmpPlainDir =>
      Directory(p.join(cacheDir.path, AppPaths.tmpPlainDirName));
  Directory get importTmpDir =>
      Directory(p.join(cacheDir.path, importTmpDirName));
  Directory get dbDir => Directory(p.join(root.path, AppPaths.dbDirName));

  /// Ruta absoluta de la BD de esta bóveda (`db/vault_secure.db`).
  String get dbFilePath => p.join(dbDir.path, dbFileName);

  /// Crea los directorios de la bóveda si faltan.
  void ensureDirs() {
    for (final d in [vaultDir, thumbsDir, cacheDir, dbDir]) {
      if (!d.existsSync()) d.createSync(recursive: true);
    }
  }

  /// Ruta absoluta de una ruta relativa de item guardada en la BD (S-15).
  String resolvePath(String relativePath) {
    final rel = AppPaths.validateRelative(relativePath);
    return p.joinAll([root.path, ...rel.split('/')]);
  }

  /// [File] de una ruta relativa de item guardada en la BD.
  File resolve(String relativePath) => File(resolvePath(relativePath));

  /// Convierte una ruta absoluta dentro de la raíz de ESTA bóveda en
  /// relativa (`/`). Lanza [ArgumentError] si está fuera.
  String relative(String absolutePath) {
    final base = p.normalize(root.path);
    final abs = p.normalize(absolutePath);
    if (!p.isWithin(base, abs)) {
      throw ArgumentError.value(
        absolutePath,
        'absolutePath',
        'Está fuera del directorio de la bóveda',
      );
    }
    return p.split(p.relative(abs, from: base)).join('/');
  }
}
