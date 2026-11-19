import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../cloud/cloud_storage.dart';

/// Tag de la cuenta de Google conectada (D75, BD v11).
///
/// `tag = hex(SHA-256(sal ‖ "google:" ‖ idEstable))`, con `idEstable` =
/// `CloudStorage.currentAccountId` (id estable de Google) o, si no hay, el
/// correo en minúsculas (con otro prefijo, para no confundir los dos).
///
/// La sal (32 bytes aleatorios) vive en la tabla `vault_meta` de la BD
/// cifrada, clave [saltKey]. Se crea al PRIMER uso (no en la migración del
/// esquema). Viaja en el snapshot y sobrevive a la rotación (`rekeyTo` copia
/// la BD entera): restaurar con la misma cuenta da el mismo tag.
///
/// Por qué hash con sal aunque la BD vaya cifrada: la BD sale del teléfono
/// (snapshot, copia de la rotación) y las filas acaban en pruebas y en el
/// diagnóstico; solo hace falta comparar igualdad, nunca saber el correo.
/// Nada de esto se registra.
class CloudAccountTagger {
  CloudAccountTagger({
    required this.cloud,
    required Future<Database> Function() dbProvider,
    Random? random,
  }) : _db = dbProvider,
       _random = random ?? Random.secure();

  final CloudStorage cloud;
  final Future<Database> Function() _db;
  final Random _random;

  static const String saltKey = 'account_salt';

  /// Tag de la sesión actual, o `null` si no hay sesión. Lanza [StateError]
  /// con la bóveda bloqueada (como cualquier acceso a la BD).
  Future<String?> current() async {
    final id = cloud.currentAccountId;
    final email = cloud.currentAccountEmail;
    final String source;
    if (id != null && id.isNotEmpty) {
      source = 'google:$id';
    } else if (email != null && email.isNotEmpty) {
      source = 'google-email:${email.trim().toLowerCase()}';
    } else {
      return null;
    }
    final salt = await _salt();
    return crypto.sha256.convert([...salt, ...utf8.encode(source)]).toString();
  }

  Future<List<int>> _salt() async {
    final db = await _db();
    final existing = await _read(db);
    if (existing != null) return existing;
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    // Dos llamadas a la vez: gana la primera (IGNORE) y las dos releen.
    await db.insert('vault_meta', {
      'key': saltKey,
      'value': hex,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await _read(db))!;
  }

  static Future<List<int>?> _read(Database db) async {
    final rows = await db.query(
      'vault_meta',
      where: 'key = ?',
      whereArgs: [saltKey],
    );
    if (rows.isEmpty) return null;
    final hex = rows.first['value'] as String;
    return [
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }
}
