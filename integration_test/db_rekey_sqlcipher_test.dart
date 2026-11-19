import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:vault/core/crypto/aes_gcm_backend.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

/// Re-cifrado de la BD con SQLCipher REAL (§6.1, D62): `ATTACH … KEY
/// x'hex'` + `sqlcipher_export` + `user_version` + triggers, reemplazo
/// atómico y copia de seguridad con la llave vieja.
///
/// Usa una BD en un directorio TEMPORAL propio (no toca la bóveda de la app):
///   flutter test integration_test/db_rekey_sqlcipher_test.dart -d ID_DISPOSITIVO
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Igual que la app (main.dart): HMAC/HKDF en Dart (el HMAC nativo rechaza
  // la sal vacía de HKDF).
  setUpAll(configureCryptography);

  Future<KeyHierarchy> keys(int seed) => KeyHierarchy.fromDek(
    Uint8List.fromList(List.generate(32, (i) => i + seed)),
  );

  Future<bool> opens(String path, KeyHierarchy k) async {
    try {
      final db = await openDatabase(
        path,
        password: VaultDatabase.passwordFor(k),
        readOnly: true,
      );
      try {
        await db.rawQuery('SELECT count(*) FROM sqlite_master');
      } finally {
        await db.close();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  testWidgets('rekeyTo con SQLCipher real: datos, triggers, versión y llaves', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('rekey_it');
    final dbPath = p.join(dir.path, 'db', VaultSchema.dbFileName);
    try {
      final k1 = await keys(1);
      final k2 = await keys(77);
      final session = VaultSession.create()..open(k1);
      final vdb = VaultDatabase.forTesting(
        session: session,
        opener: openSqlCipherDatabase,
        dbPath: dbPath,
        useSqlCipher: true,
        rekeyer: const SqlCipherExportRekeyer(),
      );
      final db = await vdb.database;
      expect(vdb.openedGen, 1);
      await db.insert('folders', {
        'id': 'f1',
        'name': 'Carpeta',
        'createdAt': '2026-01-01',
      });
      for (var i = 0; i < 50; i++) {
        await db.insert('vault_items', {
          'id': 'i$i',
          'name': 'foto $i.jpg',
          'encryptedPath': 'vault/i$i.vault',
          'fileSize': i,
          'createdAt': '2026-01-01',
        });
      }
      await db.execute(
        'CREATE TRIGGER rot_items_del AFTER DELETE ON vault_items BEGIN '
        'UPDATE rotation_state SET itemsDeleted = itemsDeleted + 1 '
        'WHERE id = 1; END',
      );

      session.openKeyring(
        VaultKeyring.dual(
          currentGen: 2,
          current: k2,
          previousGen: 1,
          previous: await keys(1),
        ),
      );
      await vdb.rekeyTo(fromGen: 1, from: k1, toGen: 2, to: k2);

      expect(await opens(dbPath, k2), isTrue, reason: 'abre con la nueva');
      expect(await opens(dbPath, k1), isFalse, reason: 'la vieja ya no abre');
      expect(await opens(vdb.rekeyBackupPath(1), k1), isTrue);
      expect(File(vdb.rekeyTmpPath(2)).existsSync(), isFalse);
      final header = File(dbPath).openSync().readSync(16);
      expect(
        String.fromCharCodes(header).startsWith('SQLite format 3'),
        isFalse,
      );

      final again = await vdb.database;
      expect(vdb.openedGen, 2);
      expect((await again.query('vault_items')).length, 50);
      expect((await again.query('folders')).single['name'], 'Carpeta');
      expect(
        (await again.rawQuery('PRAGMA user_version')).single.values.first,
        VaultSchema.version,
      );
      expect(
        (await again.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger'",
        )).map((r) => r['name']),
        ['rot_items_del'],
      );
      // El trigger funciona en la copia.
      await again.insert('rotation_state', {
        'id': 1,
        'rotationId': 'r',
        'fromGen': 1,
        'toGen': 2,
        'frozenAt': 0,
        'frozenItems': 50,
        'frozenFolders': 1,
      });
      await again.delete('vault_items', where: "id = 'i0'");
      expect((await again.query('rotation_state')).single['itemsDeleted'], 1);
      expect(await again.rawQuery('PRAGMA cipher_integrity_check'), isEmpty);

      // Idempotente.
      await vdb.rekeyTo(fromGen: 1, from: await keys(1), toGen: 2, to: k2);
      await vdb.deleteRekeyLeftovers(1);
      expect(File(vdb.rekeyBackupPath(1)).existsSync(), isFalse);
      await vdb.close();
      session.clear();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
