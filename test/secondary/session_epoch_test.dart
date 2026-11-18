// Fase 8, paso 2 (DISENO_SENUELO §4.1): sesión con bóveda, época, ticket,
// llaves ligadas a la bóveda y ganchos comunes de bloqueo.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/session_hooks.dart';
import 'package:vault/core/session/vault_session.dart';

Future<KeyHierarchy> _keys(int seed) => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i + seed)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bóveda y época', () {
    test('bloqueada: sin bóveda; abrir sin indicarla = principal', () async {
      final s = VaultSession.create();
      expect(s.slot, isNull);
      expect(s.isUnlockedAs(VaultSlot.primary), isFalse);
      expect(() => s.ticket(), throwsStateError);
      s.open(await _keys(1));
      expect(s.slot, VaultSlot.primary);
      expect(s.isUnlockedAs(VaultSlot.primary), isTrue);
      expect(s.isUnlockedAs(VaultSlot.secondary), isFalse);
    });

    test('la época cambia al abrir desde bloqueo y al bloquear, no al '
        'cambiar el anillo de la misma sesión', () async {
      final s = VaultSession.create();
      final e0 = s.epoch;
      final k1 = await _keys(1);
      s.open(k1);
      final e1 = s.epoch;
      expect(e1, greaterThan(e0));
      // Mismo DEK otra vez (doble desbloqueo): misma época.
      s.open(await _keys(1));
      expect(s.epoch, e1);
      // Rotación: anillo doble y después simple con la nueva, misma época.
      final k2 = await _keys(2);
      s.openKeyring(
        VaultKeyring.dual(
          currentGen: 2,
          current: k2,
          previousGen: 1,
          previous: s.keys,
        ),
      );
      expect(s.epoch, e1);
      s.openKeyring(VaultKeyring.single(2, k2));
      expect(s.epoch, e1);
      s.clear();
      expect(s.epoch, greaterThan(e1));
      final e2 = s.epoch;
      s.open(await _keys(3), slot: VaultSlot.secondary);
      expect(s.epoch, greaterThan(e2));
    });

    test('abrir OTRA bóveda sin bloquear: StateError y la sesión intacta; '
        'las llaves rechazadas se destruyen', () async {
      final s = VaultSession.create();
      final kp = await _keys(1);
      s.open(kp);
      final e = s.epoch;
      final ks = await _keys(2);
      expect(() => s.open(ks, slot: VaultSlot.secondary), throwsStateError);
      expect(ks.isDestroyed, isTrue);
      expect(kp.isDestroyed, isFalse);
      expect(s.slot, VaultSlot.primary);
      expect(s.keys, same(kp));
      expect(s.epoch, e);
      // Tras bloquear, sí.
      s.clear();
      final ks2 = await _keys(2);
      s.open(ks2, slot: VaultSlot.secondary);
      expect(s.slot, VaultSlot.secondary);
      expect(s.keys, same(ks2));
    });
  });

  group('ticket', () {
    test('válido mientras siga la misma bóveda y época', () async {
      final s = VaultSession.create();
      s.open(await _keys(1));
      final t = s.ticket();
      expect(t.slot, VaultSlot.primary);
      expect(t.isValid, isTrue);
      t.check();
      // Cambio del anillo en la misma sesión (rotación): sigue válido.
      s.open(await _keys(1));
      expect(t.isValid, isTrue);
      s.clear();
      expect(t.isValid, isFalse);
      expect(t.check, throwsA(isA<SessionChangedException>()));
      // Otra apertura de la MISMA bóveda: época nueva, el ticket viejo no.
      s.open(await _keys(1));
      expect(t.isValid, isFalse);
      expect(t.check, throwsStateError); // es un StateError
    });

    test('bloquear y abrir la OTRA bóveda invalida el ticket', () async {
      final s = VaultSession.create();
      s.open(await _keys(1), slot: VaultSlot.secondary);
      final t = s.ticket();
      expect(t.slot, VaultSlot.secondary);
      s.clear();
      s.open(await _keys(2));
      expect(t.isValid, isFalse);
      expect(
        WrongVaultSlotError(VaultSlot.secondary, VaultSlot.primary),
        isA<StateError>(),
      );
    });
  });

  group('llaves ligadas a la bóveda', () {
    test('filesKeyFor/thumbsKeyFor/dbCandidatesFor devuelven null o vacío con '
        'la otra bóveda abierta', () async {
      final s = VaultSession.create();
      final kp = await _keys(1);
      s.open(kp);
      expect(s.filesKeyFor(1), same(kp.files)); // por defecto: la principal
      expect(s.filesKeyFor(1, VaultSlot.primary), same(kp.files));
      expect(s.thumbsKeyFor(1, VaultSlot.primary), same(kp.thumbs));
      expect(s.filesKeyFor(1, VaultSlot.secondary), isNull);
      expect(s.thumbsKeyFor(1, VaultSlot.secondary), isNull);
      expect(s.dbCandidatesFor(VaultSlot.secondary), isEmpty);
      expect(s.dbCandidatesFor(VaultSlot.primary).single.$2, same(kp));

      s.clear();
      final ks = await _keys(2);
      s.open(ks, slot: VaultSlot.secondary);
      // Un servicio de la principal (sin indicar bóveda) NO recibe la llave
      // de la secundaria: falla cerrado.
      expect(s.filesKeyFor(1), isNull);
      expect(s.thumbsKeyFor(1), isNull);
      expect(s.dbCandidatesFor(VaultSlot.primary), isEmpty);
      expect(s.filesKeyFor(1, VaultSlot.secondary), same(ks.files));
      expect(s.dbCandidatesFor(VaultSlot.secondary).single.$2, same(ks));
    });
  });

  group('SessionHooks', () {
    late Directory base;
    setUp(() async {
      base = await Directory.systemTemp.createTemp('hooks');
      await AppPaths.init(baseDir: base);
    });
    tearDown(() async {
      AppPaths.resetForTesting();
      if (base.existsSync()) await base.delete(recursive: true);
    });

    test('se instalan una vez y, al bloquear la SECUNDARIA, borran sus '
        'temporales en claro y el diagnóstico', () async {
      final s = VaultSession.create();
      expect(SessionHooks.isInstalled(s), isFalse);
      SessionHooks.ensureInstalled(s);
      SessionHooks.ensureInstalled(s); // idempotente
      expect(SessionHooks.isInstalled(s), isTrue);

      final tmp = VaultPaths.secondary.tmpPlainDir..createSync(recursive: true);
      final plain = File(p.join(tmp.path, 'p1.mp4'))..writeAsStringSync('x');
      DiagnosticsBuffer.instance.add(DiagLevel.debug, 'prueba', 'x');
      s.open(await _keys(1), slot: VaultSlot.secondary);
      s.clear();
      expect(plain.existsSync(), isFalse);
      expect(DiagnosticsBuffer.instance.entries, isEmpty);
    });
  });
}
