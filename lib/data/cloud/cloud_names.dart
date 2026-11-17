import '../../core/services/app_paths.dart';

/// Tipo de un nombre de Vault en appDataFolder (ver [CloudNames.parse]).
enum CloudNameKind {
  /// `<id>[.kN].vault`: archivo cifrado de un item.
  file,

  /// `<id>[.kN].thumb`: miniatura cifrada de un item.
  thumb,

  /// `recovery_backup[.kN].json`: DEK de la generación N envuelta con el
  /// código de recuperación.
  recoveryBackup,

  /// `recovery_backup.bridge.kF.json`: DEK de la generación F envuelta con el
  /// código NUEVO de una rotación (respaldo puente, D61).
  bridgeBackup,

  /// `vault_db[.kN].snapshot`: copia de la BD cifrada con la llave de gen N.
  dbSnapshot,

  /// `lost_<id>.kN.vault`: blob de un item dañado en cuarentena (no se borra
  /// solo).
  quarantine,
}

/// Resultado de [CloudNames.parse].
class CloudNameInfo {
  const CloudNameInfo(this.kind, this.gen, {this.itemId});

  final CloudNameKind kind;

  /// Generación de llave del recurso. Para [CloudNameKind.bridgeBackup] es la
  /// generación que el puente ABRE (`fromGen` de la rotación).
  final int gen;

  /// Id del item (solo [CloudNameKind.file], [CloudNameKind.thumb] y
  /// [CloudNameKind.quarantine]).
  final String? itemId;

  @override
  bool operator ==(Object other) =>
      other is CloudNameInfo &&
      other.kind == kind &&
      other.gen == gen &&
      other.itemId == itemId;

  @override
  int get hashCode => Object.hash(kind, gen, itemId);

  @override
  String toString() => 'CloudNameInfo($kind, gen $gen, $itemId)';
}

/// Nombres remotos en appDataFolder (sin nombres reales de archivos).
///
/// D60: la generación de llave va en el NOMBRE. La generación 1 conserva los
/// nombres de siempre; desde la 2 se añade `.kN`. Así nunca hay dos archivos
/// con el mismo nombre cifrados con llaves distintas.
abstract final class CloudNames {
  /// Respaldo de recuperación de la generación 1 (nombre histórico).
  static const String recoveryBackup = 'recovery_backup.json';

  /// Snapshot de la BD de la generación 1 (nombre histórico).
  static const String dbSnapshot = 'vault_db.snapshot';

  static String file(String itemId, {int gen = 1}) =>
      '$itemId${AppPaths.keyGenSuffix(gen)}.vault';

  static String thumb(String itemId, {int gen = 1}) =>
      '$itemId${AppPaths.keyGenSuffix(gen)}.thumb';

  /// Respaldo de recuperación de la generación [gen].
  static String recoveryBackupFor(int gen) =>
      'recovery_backup${AppPaths.keyGenSuffix(gen)}.json';

  /// Snapshot de la BD cifrada con la llave de la generación [gen].
  static String dbSnapshotFor(int gen) =>
      'vault_db${AppPaths.keyGenSuffix(gen)}.snapshot';

  /// Respaldo puente: abre la generación [fromGen] con el código nuevo.
  static String bridgeBackup(int fromGen) =>
      'recovery_backup.bridge.k${_checkGen(fromGen)}.json';

  /// Blob en cuarentena de un item dañado de la generación [gen].
  static String quarantine(String itemId, int gen) =>
      'lost_$itemId.k${_checkGen(gen)}.vault';

  static int _checkGen(int gen) {
    AppPaths.keyGenSuffix(gen); // valida el rango
    return gen;
  }

  // Generación con sufijo opcional (≥ 2) y con sufijo obligatorio (≥ 1).
  static const String _optGen = r'(?:\.k([2-9]|[1-9][0-9]{1,3}))?';
  static const String _reqGen = r'\.k([1-9][0-9]{0,3})';

  static final RegExp _item = RegExp('^(.+?)$_optGen\\.(vault|thumb)\$');
  static final RegExp _lost = RegExp('^lost_(.+?)$_reqGen\\.vault\$');
  static final RegExp _backup = RegExp('^recovery_backup$_optGen\\.json\$');
  static final RegExp _bridge = RegExp(
    '^recovery_backup\\.bridge$_reqGen\\.json\$',
  );
  static final RegExp _snapshot = RegExp('^vault_db$_optGen\\.snapshot\$');

  /// Reconoce un nombre de Vault. Devuelve `null` para cualquier otra cosa
  /// (ids que no son UUID v4, generaciones con ceros a la izquierda o fuera
  /// de rango, `.k1` en nombres que no lo llevan, mayúsculas, rutas…).
  static CloudNameInfo? parse(String name) {
    int genOf(String? g) => g == null ? 1 : int.parse(g);

    var m = _backup.firstMatch(name);
    if (m != null) {
      return CloudNameInfo(CloudNameKind.recoveryBackup, genOf(m.group(1)));
    }
    m = _bridge.firstMatch(name);
    if (m != null) {
      return CloudNameInfo(CloudNameKind.bridgeBackup, genOf(m.group(1)));
    }
    m = _snapshot.firstMatch(name);
    if (m != null) {
      return CloudNameInfo(CloudNameKind.dbSnapshot, genOf(m.group(1)));
    }
    m = _lost.firstMatch(name);
    if (m != null) {
      final id = m.group(1)!;
      if (!AppPaths.isValidItemId(id)) return null;
      return CloudNameInfo(
        CloudNameKind.quarantine,
        genOf(m.group(2)),
        itemId: id,
      );
    }
    m = _item.firstMatch(name);
    if (m != null) {
      final id = m.group(1)!;
      if (!AppPaths.isValidItemId(id)) return null;
      return CloudNameInfo(
        m.group(3) == 'vault' ? CloudNameKind.file : CloudNameKind.thumb,
        genOf(m.group(2)),
        itemId: id,
      );
    }
    return null;
  }
}
