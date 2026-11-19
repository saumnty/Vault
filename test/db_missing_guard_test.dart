// C1 (D62, rotación de la DEK paso 2): con una bóveda cuya BD ya existió, la
// app NUNCA crea una BD vacía si falta el archivo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

import 'support/fakes.dart';

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late String dbPath;
  late InMemorySecureStore store;
  late VaultSession session;

  AuthController newAuth() => AuthController(
    storage: store,
    biometricStore: FakeBiometricKeyStore(),
    kdfParams: fastKdf,
    session: session,
  );

  VaultDatabase newDb() => VaultDatabase.forTesting(
    session: session,
    dbPath: dbPath,
    markerStore: store,
    opener: (path, {password, required options}) =>
        databaseFactoryFfi.openDatabase(path, options: options),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('c1_guard');
    dbPath = p.join(tmp.path, 'db', VaultSchema.dbFileName);
    store = InMemorySecureStore();
    session = VaultSession.create();
  });

  tearDown(() async {
    session.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'primera apertura tras crear la bóveda: crea la BD y la marca',
    () async {
      await newAuth().createVault('123456');
      expect(store.data[AuthController.dbCreatedKey], isNull);
      final vdb = newDb();
      await vdb.database;
      expect(File(dbPath).existsSync(), isTrue);
      expect(store.data[AuthController.dbCreatedKey], 'true');
      await vdb.close();
    },
  );

  test('BD ausente con bóveda existente: lanza y no crea nada', () async {
    await newAuth().createVault('123456');
    final vdb = newDb();
    final db = await vdb.database;
    await db.insert('folders', {
      'id': 'f1',
      'name': 'x',
      'createdAt': '2026-01-01T00:00:00',
    });
    await vdb.close();
    // Desaparece el archivo (p. ej. un corte a mitad de un reemplazo).
    for (final s in ['', '-wal', '-shm', '-journal']) {
      final f = File('$dbPath$s');
      if (f.existsSync()) f.deleteSync();
    }
    final again = newDb();
    await expectLater(
      again.database,
      throwsA(isA<VaultDatabaseMissingException>()),
    );
    expect(File(dbPath).existsSync(), isFalse);
    expect(again.isOpen, isFalse);
  });

  test('bóveda anterior a C1 (BD sin marca): se abre y se marca', () async {
    await newAuth().createVault('123456');
    // BD creada por una versión sin la guarda.
    final legacy = VaultDatabase.forTesting(
      session: session,
      dbPath: dbPath,
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    await legacy.database;
    await legacy.close();
    expect(store.data[AuthController.dbCreatedKey], isNull);
    final vdb = newDb();
    await vdb.database;
    expect(store.data[AuthController.dbCreatedKey], 'true');
    await vdb.close();
  });

  test('crear otra bóveda borra la marca vieja', () async {
    store.data[AuthController.dbCreatedKey] = 'true'; // resto de otra bóveda
    await newAuth().createVault('123456');
    expect(store.data[AuthController.dbCreatedKey], isNull);
    await newDb().database; // se puede crear la BD de la nueva
    expect(File(dbPath).existsSync(), isTrue);
  });

  test('discardLocalKeys borra la marca', () async {
    final auth = newAuth();
    await auth.createVault('123456');
    await newDb().database;
    expect(store.data[AuthController.dbCreatedKey], 'true');
    await auth.discardLocalKeys();
    expect(store.data[AuthController.dbCreatedKey], isNull);
  });

  test('markDatabaseCreated escribe la marca', () async {
    await newAuth().markDatabaseCreated();
    expect(store.data[AuthController.dbCreatedKey], 'true');
  });
}
