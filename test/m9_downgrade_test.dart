// M9: abrir una BD de un esquema MÁS NUEVO no debe borrar nada.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

void main() {
  sqfliteFfiInit();

  test('BD de una versión más nueva: falla sin tocar los datos', () async {
    final dir = await Directory.systemTemp.createTemp('m9');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows
      }
    });
    final path = p.join(dir.path, 'v.db');
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.execute('CREATE TABLE vault_items (id TEXT PRIMARY KEY)');
    await raw.insert('vault_items', {'id': 'real'});
    await raw.execute('PRAGMA user_version = ${VaultSchema.version + 1}');
    await raw.close();

    final session = VaultSession.create()
      ..open(
        await KeyHierarchy.fromDek(
          Uint8List.fromList(List.generate(32, (i) => i)),
        ),
      );
    final vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: path,
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    await expectLater(
      vdb.database,
      throwsA(isA<VaultSchemaTooNewException>()),
    );
    await vdb.close();
    final check = await databaseFactoryFfi.openDatabase(path);
    expect((await check.query('vault_items')).single['id'], 'real');
    expect(
      (await check.rawQuery('PRAGMA user_version')).single.values.first,
      VaultSchema.version + 1,
    );
    await check.close();
  });
}
