// Fase 8, paso 3 (DISENO_SENUELO §2.3/§4.1): una BD por bóveda, con su
// ruta y su marca C1 fijas, la bóveda exigida en cada acceso y la conexión
// ligada a la época de la sesión.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

import '../support/fakes.dart';

Future<KeyHierarchy> _keys(int seed) => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i + seed)),
);

void main() {
  sqfliteFfiInit();
  late Directory base;
  late VaultSession session;
  late InMemorySecureStore store;

  /// Abridor ffi (sin SQLCipher) con una pausa opcional ANTES de abrir.
  Completer<void>? pauseBeforeOpen;
  Future<Database> opener(
    String path, {
    String? password,
    required OpenDatabaseOptions options,
  }) async {
    final gate = pauseBeforeOpen;
    if (gate != null) await gate.future;
    return databaseFactoryFfi.openDatabase(path, options: options);
  }

  VaultDatabase db(VaultSlot slot) => VaultDatabase.forTesting(
    session: session,
    opener: opener,
    markerStore: store,
    slot: slot,
  );

  setUp(() async {
    base = await Directory.systemTemp.createTemp('db_slot');
    await AppPaths.init(baseDir: base);
    session = VaultSession.create();
    store = InMemorySecureStore();
    pauseBeforeOpen = null;
  });

  tearDown(() async {
    AppPaths.resetForTesting();
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  });

  File primaryFile() => File(VaultPaths.primary.dbFilePath);
  File secondaryFile() => File(VaultPaths.secondary.dbFilePath);

  test('la instancia principal es la de siempre (ruta y marca)', () async {
    expect(VaultDatabase.instance.slot, VaultSlot.primary);
    expect(VaultDatabase.secondaryInstance.slot, VaultSlot.secondary);
    expect(
      VaultDatabase.defaultDbPath,
      p.join(base.path, 'db', 'vault_secure.db'),
    );
    expect(
      AuthController.dbCreatedKeyFor(VaultSlot.primary),
      'vault.v1.db_created',
    );
    expect(
      AuthController.dbCreatedKeyFor(VaultSlot.secondary),
      'vault.v1.alt.db_created',
    );

    session.open(await _keys(1));
    final vdb = db(VaultSlot.primary);
    final conn = await vdb.database;
    await conn.insert('folders', {'id': 'f', 'name': 'F', 'createdAt': 'x'});
    expect(primaryFile().existsSync(), isTrue);
    expect(store.data[AuthController.dbCreatedKey], 'true');
    expect(store.data.containsKey(AuthController.altDbCreatedKey), isFalse);
    expect(VaultPaths.secondary.exists, isFalse);
    await vdb.close();
  });

  test('la secundaria crea SOLO alt/db y su propia marca', () async {
    session.open(await _keys(2), slot: VaultSlot.secondary);
    final vdb = db(VaultSlot.secondary);
    final conn = await vdb.database;
    await conn.insert('folders', {'id': 's', 'name': 'S', 'createdAt': 'x'});
    expect(secondaryFile().existsSync(), isTrue);
    expect(primaryFile().existsSync(), isFalse);
    expect(store.data[AuthController.altDbCreatedKey], 'true');
    expect(store.data.containsKey(AuthController.dbCreatedKey), isFalse);
    await vdb.close();
  });

  test(
    'con la OTRA bóveda abierta: WrongVaultSlotError y nada creado',
    () async {
      final prim = db(VaultSlot.primary);
      final sec = db(VaultSlot.secondary);

      session.open(await _keys(2), slot: VaultSlot.secondary);
      await expectLater(prim.database, throwsA(isA<WrongVaultSlotError>()));
      expect(primaryFile().existsSync(), isFalse);
      expect(store.data, isEmpty);

      session.clear();
      session.open(await _keys(1));
      await expectLater(sec.database, throwsA(isA<WrongVaultSlotError>()));
      expect(VaultPaths.secondary.exists, isFalse);
      expect(store.data, isEmpty);

      // Bloqueada: el error de siempre (StateError "bloqueada").
      session.clear();
      await expectLater(sec.database, throwsStateError);
    },
  );

  test('C1 por bóveda: la marca de la secundaria con el archivo ausente no '
      'crea nada; la de la principal no le afecta', () async {
    store.data[AuthController.altDbCreatedKey] = 'true';
    session.open(await _keys(2), slot: VaultSlot.secondary);
    await expectLater(
      db(VaultSlot.secondary).database,
      throwsA(isA<VaultDatabaseMissingException>()),
    );
    expect(secondaryFile().existsSync(), isFalse);

    // La marca de la PRINCIPAL no impide crear la BD de la secundaria.
    store.data.remove(AuthController.altDbCreatedKey);
    store.data[AuthController.dbCreatedKey] = 'true';
    final vdb = db(VaultSlot.secondary);
    await vdb.database;
    expect(secondaryFile().existsSync(), isTrue);
    await vdb.close();
  });

  test(
    'la conexión se liga a la época: otra apertura de la sesión reabre',
    () async {
      final k = await _keys(1);
      session.open(k);
      final vdb = db(VaultSlot.primary);
      final c1 = await vdb.database;
      expect(identical(await vdb.database, c1), isTrue);
      // Mismo DEK en la misma sesión (doble desbloqueo): se reutiliza.
      session.open(await _keys(1));
      expect(identical(await vdb.database, c1), isTrue);
      // Bloquear y volver a abrir: época nueva, conexión nueva.
      session.clear();
      session.open(await _keys(1));
      final c2 = await vdb.database;
      expect(identical(c2, c1), isFalse);
      await vdb.close();
    },
  );

  test('apertura que cruza "bloquear → abrir la otra": no se publica la '
      'conexión ni se escribe la marca, y la otra bóveda no se toca', () async {
    session.open(await _keys(1));
    final prim = db(VaultSlot.primary);
    pauseBeforeOpen = Completer<void>();
    final opening = prim.database;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    session.clear();
    session.open(await _keys(2), slot: VaultSlot.secondary);
    pauseBeforeOpen!.complete();
    await expectLater(opening, throwsA(isA<SessionChangedException>()));
    expect(prim.isOpen, isFalse);
    expect(store.data, isEmpty);
    expect(VaultPaths.secondary.exists, isFalse);
  });

  test('apertura que cruza un bloqueo ANTES de crear: no crea nada', () async {
    session.open(await _keys(2), slot: VaultSlot.secondary);
    // La lectura de la marca espera (await) y, si la sesión cambió entretanto,
    // no se crea ni la carpeta ni la BD.
    final slow = _SlowStore(store);
    final vdb = VaultDatabase.forTesting(
      session: session,
      opener: opener,
      markerStore: slow,
      slot: VaultSlot.secondary,
    );
    slow.gate = Completer<void>();
    final opening = vdb.database;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    session.clear();
    slow.gate!.complete();
    await expectLater(opening, throwsA(isA<SessionChangedException>()));
    expect(VaultPaths.secondary.exists, isFalse);
    expect(store.data, isEmpty);
  });

  test('el snapshot solo existe en la principal', () async {
    session.open(await _keys(2), slot: VaultSlot.secondary);
    final sec = db(VaultSlot.secondary);
    await sec.database;
    await expectLater(
      sec.exportEncryptedSnapshot(),
      throwsA(isA<WrongVaultSlotError>()),
    );
    expect(File('${secondaryFile().path}.snapshot').existsSync(), isFalse);
    await sec.close();
  });
}

/// Almacén cuya LECTURA espera a [gate] (para cruzar un bloqueo).
class _SlowStore extends InMemorySecureStore {
  _SlowStore(this._inner);
  final InMemorySecureStore _inner;
  Completer<void>? gate;

  @override
  Future<String?> read(String key) async {
    final g = gate;
    if (g != null) await g.future;
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
