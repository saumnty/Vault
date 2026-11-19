import 'package:sqflite_sqlcipher/sqflite.dart';

/// Copia una BD abierta a otro archivo cifrado con OTRA llave (D62, §6.1).
/// Inyectable: la app usa SQLCipher ([SqlCipherExportRekeyer]); las pruebas
/// de escritorio (sqlite sin SQLCipher) usan un fake.
abstract interface class DbRekeyer {
  /// Exporta el contenido completo de [source] (esquema, datos, índices y
  /// triggers) a un archivo NUEVO en [destPath], cifrado con [newPassword]
  /// (llave cruda `x'<hex>'`), y le pone `user_version` = [userVersion].
  /// [destPath] no debe existir.
  Future<void> exportTo(
    Database source,
    String destPath,
    String newPassword, {
    required int userVersion,
  });
}

/// `ATTACH DATABASE … KEY …` + `SELECT sqlcipher_export(…)` (SQLCipher 4).
///
/// `sqlcipher_export` NO copia `user_version`: se fija aparte en la BD
/// adjunta. La llave se pasa como parámetro; si la plataforma no admitiera
/// parámetros en `ATTACH … KEY`, se repite con un literal (la llave es hex y
/// la ruta se escapa).
class SqlCipherExportRekeyer implements DbRekeyer {
  const SqlCipherExportRekeyer();

  static const String _alias = 'rot_rekey';

  @override
  Future<void> exportTo(
    Database source,
    String destPath,
    String newPassword, {
    required int userVersion,
  }) async {
    if (!RegExp(r"^x'[0-9a-f]{64}'$").hasMatch(newPassword)) {
      throw ArgumentError('Llave SQLCipher con formato inesperado');
    }
    try {
      await source.execute('ATTACH DATABASE ? AS $_alias KEY ?', [
        destPath,
        newPassword,
      ]);
    } on DatabaseException {
      final path = destPath.replaceAll("'", "''");
      await source.execute(
        "ATTACH DATABASE '$path' AS $_alias KEY \"$newPassword\"",
      );
    }
    try {
      await source.rawQuery("SELECT sqlcipher_export('$_alias')");
      await source.execute('PRAGMA $_alias.user_version = $userVersion');
    } finally {
      await source.execute('DETACH DATABASE $_alias');
    }
  }
}
