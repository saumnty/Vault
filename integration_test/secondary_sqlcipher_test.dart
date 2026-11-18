import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:vault/core/crypto/aes_gcm_backend.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

/// Fase 8 (DISENO_SENUELO §11.2-18): BD de la bóveda SECUNDARIA con SQLCipher
/// REAL. Cada BD abre SOLO con la llave de su bóveda, la principal abre igual
/// tras crear y borrar la secundaria, y ninguna instancia sirve la BD de la
/// otra bóveda.
///
/// Usa un directorio TEMPORAL propio como raíz (no toca la bóveda de la app):
///   flutter test integration_test/secondary_sqlcipher_test.dart -d ID_DISPOSITIVO
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureCryptography);

  Future<KeyHierarchy> keys(int seed) => KeyHierarchy.fromDek(
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) % 256)),
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

  testWidgets('dos BD, dos llaves: ninguna abre con la de la otra', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('alt_sqlcipher_it');
    await AppPaths.init(baseDir: dir);
    try {
      final kp = await keys(1);
      final ks = await keys(99);
      final session = VaultSession.create();
      VaultDatabase db(VaultSlot slot) => VaultDatabase.forTesting(
        session: session,
        opener: openSqlCipherDatabase,
        useSqlCipher: true,
        slot: slot,
      );

      // Principal.
      session.open(kp);
      final prim = db(VaultSlot.primary);
      final p = await prim.database;
      await p.insert('folders', {
        'id': 'p1',
        'name': 'Principal',
        'createdAt': '2026-01-01',
      });
      await prim.close();
      session.clear();

      // Secundaria.
      VaultPaths.secondary.ensureDirs();
      session.open(await keys(99), slot: VaultSlot.secondary);
      final sec = db(VaultSlot.secondary);
      final s = await sec.database;
      await s.insert('folders', {
        'id': 's1',
        'name': 'Secundaria',
        'createdAt': '2026-01-01',
      });
      // Con la secundaria abierta la instancia principal no sirve nada.
      await expectLater(prim.database, throwsA(isA<WrongVaultSlotError>()));
      await sec.close();
      session.clear();

      final primaryPath = VaultPaths.primary.dbFilePath;
      final secondaryPath = VaultPaths.secondary.dbFilePath;
      expect(await opens(primaryPath, kp), isTrue);
      expect(await opens(primaryPath, ks), isFalse);
      expect(await opens(secondaryPath, ks), isTrue);
      expect(await opens(secondaryPath, kp), isFalse);
      // Sin "SQLite format" en claro.
      for (final path in [primaryPath, secondaryPath]) {
        final head = File(path).openSync().readSync(16);
        expect(String.fromCharCodes(head).startsWith('SQLite format'), isFalse);
      }

      // Borrar la secundaria no toca la principal.
      VaultPaths.secondary.root.deleteSync(recursive: true);
      session.open(await keys(1));
      final again = await db(VaultSlot.primary).database;
      final rows = await again.query('folders');
      expect(rows.single['id'], 'p1');
      await again.close();
      session.clear();
    } finally {
      AppPaths.resetForTesting();
      await dir.delete(recursive: true);
    }
  });
}
