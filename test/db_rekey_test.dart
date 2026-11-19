// §6.1/§6.2 (C1, D62; rotación de la DEK paso 7): re-cifrado de la BD por
// copia verificada y reemplazo atómico, sin ningún instante sin BD.
//
// sqlite de escritorio no tiene SQLCipher: aquí la "llave" es un marcador
// dentro de la BD (tabla `_fake_key`) que el opener comprueba, y la copia la
// hace `VACUUM INTO`. El SQLCipher real se prueba en
// integration_test/db_rekey_sqlcipher_test.dart.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

import 'support/fakes.dart';

Future<KeyHierarchy> _keys(int seed) => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i + seed)),
);

/// "SQLCipher" de pruebas: la BD guarda su llave y rechaza otra.
Future<Database> fakeCipherOpener(
  String path, {
  String? password,
  required OpenDatabaseOptions options,
}) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: options);
  final has = (await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE name = '_fake_key'",
  )).isNotEmpty;
  if (!has) {
    await db.execute('CREATE TABLE _fake_key (k TEXT)');
    await db.insert('_fake_key', {'k': password});
    return db;
  }
  final k = (await db.query('_fake_key')).first['k'];
  if (k != password) {
    await db.close();
    throw Exception('file is not a database');
  }
  return db;
}

/// Copia con `VACUUM INTO` y cambia la llave del marcador.
class FakeRekeyer implements DbRekeyer {
  Future<void> Function(String dest)? afterExport;

  @override
  Future<void> exportTo(
    Database source,
    String destPath,
    String newPassword, {
    required int userVersion,
  }) async {
    final escaped = destPath.replaceAll("'", "''");
    await source.execute("VACUUM INTO '$escaped'");
    final dest = await databaseFactoryFfi.openDatabase(destPath);
    await dest.update('_fake_key', {'k': newPassword});
    await dest.execute('PRAGMA user_version = $userVersion');
    await dest.close();
    await afterExport?.call(destPath);
  }
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late String dbPath;
  late VaultSession session;
  late KeyHierarchy k1;
  late KeyHierarchy k2;
  late FakeRekeyer rekeyer;
  late InMemorySecureStore store;

  VaultDatabase newDb() => VaultDatabase.forTesting(
    session: session,
    dbPath: dbPath,
    opener: fakeCipherOpener,
    useSqlCipher: true,
    markerStore: store,
    rekeyer: rekeyer,
  );

  Future<bool> opensWith(String path, KeyHierarchy k) async {
    try {
      final db = await fakeCipherOpener(
        path,
        password: VaultDatabase.passwordFor(k),
        options: OpenDatabaseOptions(),
      );
      await db.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('db_rekey');
    dbPath = p.join(tmp.path, 'db', VaultSchema.dbFileName);
    store = InMemorySecureStore();
    rekeyer = FakeRekeyer();
    k1 = await _keys(1);
    k2 = await _keys(50);
    session = VaultSession.create()..open(k1);
    // BD real de la gen 1 con datos y un trigger de la rotación.
    final vdb = newDb();
    final db = await vdb.database;
    await db.insert('folders', {
      'id': 'f1',
      'name': 'Carpeta',
      'createdAt': '2026-01-01',
    });
    for (final id in ['a', 'b', 'c']) {
      await db.insert('vault_items', {
        'id': id,
        'name': '$id.jpg',
        'encryptedPath': 'vault/$id.vault',
        'fileSize': 1,
        'createdAt': '2026-01-01',
      });
    }
    await db.insert('tags', {'id': 't', 'name': 'T', 'createdAt': 'x'});
    await db.insert('item_tags', {'itemId': 'a', 'tagId': 't'});
    await db.execute(
      'CREATE TRIGGER rot_items_del AFTER DELETE ON vault_items BEGIN '
      'UPDATE rotation_state SET itemsDeleted = itemsDeleted + 1 '
      'WHERE id = 1; END',
    );
    await vdb.close();
    // Sesión de la rotación: las dos llaves.
    session.openKeyring(
      VaultKeyring.dual(
        currentGen: 2,
        current: k2,
        previousGen: 1,
        previous: await _keys(1),
      ),
    );
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> rekey(VaultDatabase vdb) =>
      vdb.rekeyTo(fromGen: 1, from: k1, toGen: 2, to: k2);

  test('re-cifra por copia: datos, triggers y versión intactos', () async {
    final vdb = newDb();
    await vdb.database; // conexión abierta: se cierra sola
    expect(vdb.openedGen, 1);
    await rekey(vdb);
    expect(await opensWith(dbPath, k2), isTrue);
    expect(await opensWith(dbPath, k1), isFalse);
    // Copia de seguridad con la llave vieja; sin copia de trabajo.
    expect(await opensWith(vdb.rekeyBackupPath(1), k1), isTrue);
    expect(File(vdb.rekeyTmpPath(2)).existsSync(), isFalse);
    final db = await vdb.database;
    expect(vdb.openedGen, 2);
    expect((await db.query('vault_items')).length, 3);
    expect((await db.query('folders')).single['name'], 'Carpeta');
    expect((await db.query('item_tags')).single['tagId'], 't');
    expect(
      (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger'",
      )).map((r) => r['name']),
      ['rot_items_del'],
    );
    expect(
      (await db.rawQuery('PRAGMA user_version')).single.values.first,
      VaultSchema.version,
    );
    // Idempotente.
    await vdb.close();
    await rekey(vdb);
    expect(await opensWith(dbPath, k2), isTrue);
    await vdb.deleteRekeyLeftovers(1);
    expect(File(vdb.rekeyBackupPath(1)).existsSync(), isFalse);
  });

  test('D75 (v11): la sal de vault_meta, los tags y diag_events sobreviven '
      'al re-cifrado (y cuentan en la verificación)', () async {
    // La BD sigue con la llave de la gen 1 (la sesión tiene las dos).
    var vdb = newDb();
    var db = await vdb.database;
    await db.insert('vault_meta', {'key': 'account_salt', 'value': 'ab' * 32});
    await db.insert('diag_events', {
      'at': 1,
      'level': 'debug',
      'category': 'sync',
      'message': 'x',
    });
    await db.update('vault_items', {
      'cloudAccountTag': 'tagA',
      'thumbAccountTag': 'tagA',
    }, where: "id = 'a'");
    await vdb.close();
    vdb = newDb();
    await rekey(vdb);
    db = await vdb.database;
    expect(
      (await db.query('vault_meta')).single['value'],
      'ab' * 32,
    );
    expect((await db.query('diag_events')).length, 1);
    final a = (await db.query('vault_items', where: "id = 'a'")).single;
    expect(a['cloudAccountTag'], 'tagA');
    expect(a['thumbAccountTag'], 'tagA');
    await vdb.close();
  });

  test('D75: una copia sin la fila de vault_meta no supera la '
      'verificación', () async {
    var vdb = newDb();
    final db = await vdb.database;
    await db.insert('vault_meta', {'key': 'account_salt', 'value': 'cd' * 32});
    await vdb.close();
    rekeyer.afterExport = (dest) async {
      final d = await databaseFactoryFfi.openDatabase(dest);
      await d.delete('vault_meta');
      await d.close();
    };
    vdb = newDb();
    await expectLater(
      rekey(vdb),
      throwsA(isA<VaultRekeyVerificationException>()),
    );
    expect(await opensWith(dbPath, k1), isTrue);
  });

  test(
    'verificación fallida: la BD original queda intacta y sin restos',
    () async {
      rekeyer.afterExport = (dest) async {
        final d = await databaseFactoryFfi.openDatabase(dest);
        await d.delete('vault_items', where: "id = 'c'");
        await d.close();
      };
      final vdb = newDb();
      await expectLater(
        rekey(vdb),
        throwsA(isA<VaultRekeyVerificationException>()),
      );
      expect(await opensWith(dbPath, k1), isTrue);
      expect(File(vdb.rekeyTmpPath(2)).existsSync(), isFalse);
      expect(File(vdb.rekeyBackupPath(1)).existsSync(), isFalse);
      final db = await vdb.database;
      expect(vdb.openedGen, 1);
      expect((await db.query('vault_items')).length, 3);
    },
  );

  test('copia que aún abre con la llave vieja: se rechaza', () async {
    rekeyer.afterExport = (dest) async {
      final d = await databaseFactoryFfi.openDatabase(dest);
      await d.update('_fake_key', {'k': VaultDatabase.passwordFor(k1)});
      await d.close();
    };
    await expectLater(
      rekey(newDb()),
      throwsA(isA<VaultRekeyVerificationException>()),
    );
    expect(await opensWith(dbPath, k1), isTrue);
  });

  test('bloqueo a mitad (antes del rename): aborta sin tocar la BD', () async {
    final oldKeys = await _keys(1); // k1 se destruye al bloquear
    rekeyer.afterExport = (_) async => session.clear();
    final vdb = newDb();
    await expectLater(rekey(vdb), throwsStateError);
    expect(await opensWith(dbPath, oldKeys), isTrue);
    expect(File(vdb.rekeyTmpPath(2)).existsSync(), isFalse);
    expect(File(vdb.rekeyBackupPath(1)).existsSync(), isFalse);
  });

  test('D67: bloquear y volver a abrir la MISMA bóveda a mitad también '
      'aborta (época nueva) sin tocar la BD', () async {
    final oldKeys = await _keys(1);
    rekeyer.afterExport = (_) async {
      session.clear();
      session.open(await _keys(1));
    };
    final vdb = newDb();
    await expectLater(rekey(vdb), throwsA(isA<SessionChangedException>()));
    expect(await opensWith(dbPath, oldKeys), isTrue);
    expect(File(vdb.rekeyTmpPath(2)).existsSync(), isFalse);
    expect(File(vdb.rekeyBackupPath(1)).existsSync(), isFalse);
  });

  test('D67: una instancia de la secundaria no se re-cifra', () async {
    final vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: dbPath,
      opener: fakeCipherOpener,
      useSqlCipher: true,
      rekeyer: rekeyer,
      slot: VaultSlot.secondary,
    );
    await expectLater(rekey(vdb), throwsStateError);
    expect(await opensWith(dbPath, k1), isTrue);
  });

  test('corte tras exportar (queda .tmp): se repite sin problema', () async {
    final vdb = newDb();
    File(vdb.rekeyTmpPath(2))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]); // copia a medias
    await rekey(vdb);
    expect(await opensWith(dbPath, k2), isTrue);
  });

  test('corte tras copiar el respaldo (antes del rename): se repite', () async {
    final vdb = newDb();
    File(dbPath).copySync(vdb.rekeyBackupPath(1));
    await rekey(vdb);
    expect(await opensWith(dbPath, k2), isTrue);
    expect(await opensWith(vdb.rekeyBackupPath(1), k1), isTrue);
  });

  test('database espera al re-cifrado y luego abre con la nueva', () async {
    final release = Completer<void>();
    rekeyer.afterExport = (_) => release.future;
    final vdb = newDb();
    final running = rekey(vdb);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(vdb.isRekeying, isTrue);
    var opened = false;
    final waiting = vdb.database.then((_) => opened = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(opened, isFalse, reason: 'la puerta está cerrada');
    release.complete();
    await running;
    await waiting;
    expect(vdb.openedGen, 2);
  });

  group('§6.2 reparación sin BD (marca escrita)', () {
    setUp(() => store.data[AuthController.dbCreatedKey] = 'true');

    test('con la copia de trabajo válida (llave nueva)', () async {
      final vdb = newDb();
      await rekey(vdb);
      // Simula el estado "tmp listo, sin db": se renombra al revés.
      File(dbPath).renameSync(vdb.rekeyTmpPath(2));
      final db = await vdb.database;
      expect(vdb.openedGen, 2);
      expect((await db.query('vault_items')).length, 3);
      expect(File(vdb.rekeyTmpPath(2)).existsSync(), isFalse);
    });

    test('solo con la copia de seguridad (llave vieja)', () async {
      final vdb = newDb();
      File(dbPath).renameSync(vdb.rekeyBackupPath(1));
      final db = await vdb.database;
      expect(vdb.openedGen, 1);
      expect((await db.query('vault_items')).length, 3);
    });

    test('restos que no abren con ninguna llave: no se crea nada', () async {
      final vdb = newDb();
      File(dbPath).renameSync(vdb.rekeyTmpPath(2));
      session.open(await _keys(99), gen: 3); // otra DEK
      await expectLater(
        vdb.database,
        throwsA(isA<VaultDatabaseMissingException>()),
      );
      expect(File(dbPath).existsSync(), isFalse);
    });
  });

  test('sin SQLCipher no se re-cifra', () async {
    final vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: dbPath,
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    await expectLater(rekey(vdb), throwsStateError);
  });
}
