// Fase 8, paso 9 (DISENO_SENUELO §11.2-2, 5, 6, 8): aislamiento total en los
// DOS sentidos (PIN, llaves, archivos, BD) y limpieza al bloquear.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/session_hooks.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';

import '../support/rotation_env.dart' show fakeCipherOpener;
import 'support/secondary_env.dart';

void main() {
  sqfliteFfiInit();
  late SecondaryEnv e;
  final c = CryptoService();

  setUp(() async {
    e = SecondaryEnv();
    await e.setUp();
    await e.createSecondary();
  });
  tearDown(() => e.tearDown());

  Future<KeyHierarchy> keysOf(String pin) async {
    expect(await e.unlock(pin), isTrue);
    return KeyHierarchy.fromDek(e.session.keys.dekBytes());
  }

  VaultDatabase db(VaultSlot slot) => VaultDatabase.forTesting(
    session: e.session,
    opener: fakeCipherOpener,
    useSqlCipher: true,
    markerStore: e.store,
    slot: slot,
  );

  test(
    'cada PIN abre SOLO su bóveda (en los dos sentidos y repetido)',
    () async {
      for (var i = 0; i < 3; i++) {
        expect(await e.unlock(pinPrimary), isTrue);
        expect(e.session.slot, VaultSlot.primary);
        expect(await e.unlock(pinSecondary), isTrue);
        expect(e.session.slot, VaultSlot.secondary);
      }
      final kp = await keysOf(pinPrimary);
      final ks = await keysOf(pinSecondary);
      expect(kp.keyCheck, isNot(ks.keyCheck));
      expect(
        VaultDatabase.passwordFor(kp),
        isNot(VaultDatabase.passwordFor(ks)),
      );
    },
  );

  test('archivos y miniaturas: ninguno abre con las llaves de la otra '
      '(ambos sentidos)', () async {
    final kp = await keysOf(pinPrimary);
    final ks = await keysOf(pinSecondary);
    final plain = utf8.encode('contenido ' * 500);
    for (final (own, other) in [(kp, ks), (ks, kp)]) {
      final f = await c.encryptBytes(plain, own.files);
      final t = await c.encryptBytes(plain, own.thumbs);
      expect(await c.decryptBytes(f, own.files), plain);
      await expectLater(c.decryptBytes(f, other.files), throwsA(anything));
      await expectLater(c.decryptBytes(t, other.thumbs), throwsA(anything));
      // Tampoco con la otra subllave de la misma bóveda (separación HKDF).
      await expectLater(c.decryptBytes(f, own.thumbs), throwsA(anything));
    }
  });

  test('BD: cada una se crea en SU ruta y no abre con la llave de la otra; '
      'la instancia de una bóveda no sirve con la otra abierta', () async {
    final kp = await keysOf(pinPrimary);
    final prim = db(VaultSlot.primary);
    await (await prim.database).insert('folders', {
      'id': 'p',
      'name': 'P',
      'createdAt': 'x',
    });
    await prim.close();
    final ks = await keysOf(pinSecondary);
    final sec = db(VaultSlot.secondary);
    await (await sec.database).insert('folders', {
      'id': 's',
      'name': 'S',
      'createdAt': 'x',
    });
    await expectLater(prim.database, throwsA(isA<WrongVaultSlotError>()));
    await sec.close();
    expect(await e.unlock(pinPrimary), isTrue);
    await expectLater(sec.database, throwsA(isA<WrongVaultSlotError>()));

    Future<bool> opens(String path, KeyHierarchy k) async {
      try {
        final d = await fakeCipherOpener(
          path,
          password: VaultDatabase.passwordFor(k),
          options: OpenDatabaseOptions(),
        );
        await d.close();
        return true;
      } catch (_) {
        return false;
      }
    }

    final pp = VaultPaths.primary.dbFilePath;
    final sp = VaultPaths.secondary.dbFilePath;
    expect(pp, isNot(sp));
    expect(await opens(pp, kp), isTrue);
    expect(await opens(pp, ks), isFalse);
    expect(await opens(sp, ks), isTrue);
    expect(await opens(sp, kp), isFalse);
    expect(e.store.data[AuthController.dbCreatedKey], 'true');
    expect(e.store.data[AuthController.altDbCreatedKey], 'true');
  });

  test(
    'llaves ligadas: con una bóveda abierta, las de la otra son null',
    () async {
      expect(await e.unlock(pinSecondary), isTrue);
      expect(e.session.filesKeyFor(1), isNull);
      expect(e.session.thumbsKeyFor(1, VaultSlot.primary), isNull);
      expect(e.session.filesKeyFor(1, VaultSlot.secondary), isNotNull);
      expect(await e.unlock(pinPrimary), isTrue);
      expect(e.session.filesKeyFor(1, VaultSlot.secondary), isNull);
      expect(e.session.filesKeyFor(1), isNotNull);
    },
  );

  test('limpieza al bloquear la secundaria: temporales en claro, diagnóstico, '
      'conexión a la BD y llaves', () async {
    SessionHooks.ensureInstalled(e.session);
    final sec = db(VaultSlot.secondary);
    expect(await e.unlock(pinSecondary), isTrue);
    await sec.database;
    final keys = e.session.keys;
    final tmp = VaultPaths.secondary.tmpPlainDir..createSync(recursive: true);
    final plain = File(p.join(tmp.path, 'video.mp4'))
      ..writeAsStringSync('en claro');
    final primTmp = VaultPaths.primary.tmpPlainDir..createSync(recursive: true);
    final primPlain = File(p.join(primTmp.path, 'p.mp4'))
      ..writeAsStringSync('en claro');
    DiagnosticsBuffer.instance.add(DiagLevel.debug, 'x', 'y');
    e.auth.lock();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(plain.existsSync(), isFalse);
    expect(primPlain.existsSync(), isFalse);
    expect(DiagnosticsBuffer.instance.isEmpty, isTrue);
    expect(sec.isOpen, isFalse);
    expect(keys.isDestroyed, isTrue);
    expect(e.session.slot, isNull);
  });
}
