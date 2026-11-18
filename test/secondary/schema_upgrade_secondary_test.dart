// Fase 8, paso 9 (DISENO_SENUELO §2.3, h12): PLANTILLA de migraciones sobre
// la BD de la bóveda SECUNDARIA.
//
// La secundaria se crea con el esquema vigente (v10 hoy) y puede quedarse sin
// abrir muchas versiones: la próxima vez que se abra se actualiza de golpe
// desde la versión con que se creó. Cada migración futura `vN → vN+1` debe
// añadir aquí su caso (BD secundaria creada en vN con datos → se abre con la
// app nueva → datos intactos y esquema nuevo), igual que hace
// `test/schema_v10_test.dart` con la principal.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

import '../support/fakes.dart';

void main() {
  sqfliteFfiInit();
  late Directory base;
  late VaultSession session;
  late InMemorySecureStore store;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('alt_schema');
    await AppPaths.init(baseDir: base);
    VaultPaths.secondary.ensureDirs();
    session = VaultSession.create();
    store = InMemorySecureStore();
    session.open(
      await KeyHierarchy.fromDek(Uint8List.fromList(List.filled(32, 5))),
      slot: VaultSlot.secondary,
    );
  });

  tearDown(() async {
    session.clear();
    AppPaths.resetForTesting();
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  });

  VaultDatabase secondaryDb() => VaultDatabase.forTesting(
    session: session,
    opener: (path, {password, required options}) =>
        databaseFactoryFfi.openDatabase(path, options: options),
    markerStore: store,
    slot: VaultSlot.secondary,
  );

  /// Crea en la ruta de la secundaria una BD con el esquema de la versión
  /// [version] (hoy solo existe la vigente) y datos de ejemplo.
  Future<void> seedAt(int version) async {
    final db = await databaseFactoryFfi.openDatabase(
      VaultPaths.secondary.dbFilePath,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (d, v) => VaultSchema.create(d),
      ),
    );
    await db.insert('folders', {'id': 'f', 'name': 'F', 'createdAt': 'x'});
    await db.insert('vault_items', {
      'id': 'i',
      'name': 'a.jpg',
      'encryptedPath': 'vault/i.vault',
      'fileSize': 1,
      'createdAt': 'x',
      'keyGen': 1,
    });
    await db.insert('tags', {'id': 't', 'name': 'T', 'createdAt': 'x'});
    await db.insert('item_tags', {'itemId': 'i', 'tagId': 't'});
    await db.close();
    store.data['vault.v1.alt.db_created'] = 'true';
  }

  for (final from in [10]) {
    test('secundaria creada en v$from se abre con la app actual '
        '(v${VaultSchema.version}) sin perder nada', () async {
      expect(from, lessThanOrEqualTo(VaultSchema.version));
      await seedAt(from);
      final vdb = secondaryDb();
      final db = await vdb.database;
      expect(
        (await db.rawQuery('PRAGMA user_version')).single.values.first,
        VaultSchema.version,
      );
      expect((await db.query('folders')).single['id'], 'f');
      expect((await db.query('vault_items')).single['keyGen'], 1);
      expect((await db.query('item_tags')).single['tagId'], 't');
      for (final t in [
        'sync_queue',
        'migration_state',
        'rotation_state',
        'rotation_old_files',
      ]) {
        expect(await db.query(t), isEmpty, reason: '$t vacía en la secundaria');
      }
      await vdb.close();
      // La BD de la principal no se creó.
      expect(File(VaultPaths.primary.dbFilePath).existsSync(), isFalse);
    });
  }

  test('una BD secundaria MÁS NUEVA que la app no se toca (D59)', () async {
    await seedAt(VaultSchema.version);
    final raw = await databaseFactoryFfi.openDatabase(
      VaultPaths.secondary.dbFilePath,
    );
    await raw.execute('PRAGMA user_version = ${VaultSchema.version + 1}');
    await raw.close();
    final before = File(VaultPaths.secondary.dbFilePath).readAsBytesSync();
    await expectLater(
      secondaryDb().database,
      throwsA(isA<VaultSchemaTooNewException>()),
    );
    expect(File(VaultPaths.secondary.dbFilePath).readAsBytesSync(), before);
  });
}
