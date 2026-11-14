import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';

/// Prueba en emulador/dispositivo con SQLCipher REAL:
///   flutter test integration_test/vault_database_sqlcipher_test.dart -d ID_DISPOSITIVO
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SQLCipher abre con la llave derivada, rechaza otra y cierra al bloquear', (
    tester,
  ) async {
    await AppPaths.init();
    final dbFile = File('${AppPaths.dbDir.path}/${VaultSchema.dbFileName}');
    if (dbFile.existsSync()) dbFile.deleteSync();

    final session = VaultSession();
    final keysA = await KeyHierarchy.fromDek(
      Uint8List.fromList(List.generate(32, (i) => i + 1)),
    );
    session.open(keysA);

    final vdb = VaultDatabase.instance;
    final repo = VaultDataRepository();
    await repo.insertItem(
      const VaultItemModel(
        id: 'it1',
        name: 'foto.jpg',
        encryptedPath: 'vault/it1.vault',
        fileSize: 3,
        mimeType: 'image/jpeg',
        createdAt: '2026-01-01T00:00:00',
        syncStatus: SyncStatus.pendiente,
      ),
    );
    expect((await repo.getItem('it1'))!.name, 'foto.jpg');

    // Bloquear cierra la conexión.
    session.clear();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(vdb.isOpen, isFalse);
    await expectLater(vdb.database, throwsStateError);

    // Con la misma llave se reabre y los datos siguen ahí.
    session.open(
      await KeyHierarchy.fromDek(
        Uint8List.fromList(List.generate(32, (i) => i + 1)),
      ),
    );
    expect((await repo.getItem('it1'))!.syncStatus, SyncStatus.pendiente);
    await vdb.close();

    // Con otra llave el archivo no se puede leer (está cifrado).
    final wrong = await KeyHierarchy.fromDek(
      Uint8List.fromList(List.generate(32, (i) => i + 100)),
    );
    final wrongPw = wrong.sqlcipher.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    Object? error;
    try {
      final bad = await openDatabase(dbFile.path, password: wrongPw);
      await bad.query('vault_items');
      await bad.close();
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: 'una llave incorrecta no debe leer la BD');

    // El archivo no es SQLite en claro.
    final header = dbFile.openSync().readSync(16);
    expect(String.fromCharCodes(header).startsWith('SQLite format 3'), isFalse);

    session.clear();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
}
