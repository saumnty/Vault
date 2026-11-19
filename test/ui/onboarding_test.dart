import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/recovery_challenge.dart';
import 'package:vault/core/security/auto_lock.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/features/onboarding/widgets/recovery_code_steps.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/main.dart';

import '../support/fake_cloud.dart';
import '../support/fakes.dart';
import '../support/ui_helpers.dart';

const pin = '246800';
const _code = 'ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2';

/// Entorno: almacén compartido (simula cerrar y reabrir la app).
class _Env {
  final store = InMemorySecureStore();
  final bio = FakeBiometricKeyStore();
  final cloud = FakeCloudStorage(email: null);
  final suspension = AutoLockSuspension();
  late final SyncService sync = SyncService(
    cloud: cloud,
    queue: SyncQueueRepository(), // no se usa: isUnlocked es false
    items: VaultDataRepository(),
    network: FakeNetworkMonitor(),
    prefs: SyncPreferences(store),
    isUnlocked: () => false, // el onboarding solo usa signIn/summary
    resolvePath: (rel) => throw UnimplementedError(),
    recoveryBackupProvider: () async => null,
    snapshotProvider: () async => throw UnimplementedError(),
    scheduleWakeups: false,
  );

  AuthController newAuth() => AuthController(
    storage: store,
    biometricStore: bio,
    kdfParams: fastKdf,
    session: VaultSession.create(),
  );

  Widget app(
    AuthController auth, {
    AutoLockDelay delay = AutoLockDelay.minute1,
  }) => VaultApp(
    authController: auth,
    services: fakeServices(FakeVaultRepository(), sync: sync),
    autoLockSuspension: suspension,
    autoLockDelay: delay,
  );
}

Future<void> _digits(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.bySemanticsLabel('Dígito $d'));
    await tester.pump();
  }
}

/// Deja terminar la derivación de llaves (Argon2 en Dart usa timers reales).
Future<void> _crypto(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Crea el PIN y su confirmación en la pantalla de PIN del onboarding.
Future<void> _createPin(WidgetTester tester) async {
  await _digits(tester, pin);
  await tester.pump();
  expect(find.text('Confirma tu PIN'), findsOneWidget);
  await _digits(tester, pin);
  await _crypto(tester);
  await _settle(tester);
}

/// Código mostrado en la pantalla (grupos de 4 unidos con guiones).
String _shownCode(WidgetTester tester) {
  final texts = tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('recovery-code-box')),
      matching: find.byType(Text),
    ),
  );
  return texts.map((t) => t.data!).join('-');
}

/// Caracteres pedidos por la pantalla de confirmación para [code].
String _requested(WidgetTester tester, String code) {
  final label = tester
      .widget<Text>(find.textContaining('Escribe los caracteres'))
      .data!;
  final positions = RegExp(
    r'(\d+)\.º',
  ).allMatches(label).map((m) => int.parse(m.group(1)!)).toList();
  expect(positions, hasLength(4));
  final n = RecoveryCode.normalize(code)!;
  return [for (final p in positions) n[p - 1]].join();
}

Future<void> _enterConfirm(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('confirm-code-field')),
    text,
  );
  await tester.pump();
}

void main() {
  group('Onboarding: flujo completo', () {
    testWidgets('bienvenida -> PIN -> código -> confirmar (error y acierto) -> '
        'biometría -> Drive -> bóveda', (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      final auth = env.newAuth();
      await tester.pumpWidget(env.app(auth));
      await tester.pumpAndSettle();

      // 1) Bienvenida: tres tarjetas con Semantics en español.
      expect(find.text('Bienvenido a Vault'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('^Cifrado en tu teléfono')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^Respaldo en tu Google Drive')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^Código de recuperación')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Paso 1 de 6'), findsOneWidget);
      await tester.tap(find.text('Empezar'));
      await tester.pumpAndSettle();

      // 2) PIN + confirmación.
      expect(find.text('Crea un nuevo PIN'), findsOneWidget);
      expect(find.bySemanticsLabel('Paso 2 de 6'), findsOneWidget);
      await _createPin(tester);

      // 3) Código: grupos de 4, sin copiar; bandera de onboarding pendiente.
      expect(find.text('Tu código de recuperación'), findsOneWidget);
      expect(find.textContaining('Copiar'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      final code = _shownCode(tester);
      expect(RecoveryCode.normalize(code), isNotNull);
      expect(code.split('-'), hasLength(6));
      expect(await auth.isOnboardingPending(), isTrue);

      await tester.tap(find.text('Ya lo anoté'));
      await tester.pumpAndSettle();

      // 4) Confirmar: no se puede avanzar sin acertar.
      expect(find.text('Confirma tu código'), findsOneWidget);
      expect(find.bySemanticsLabel('Paso 4 de 6'), findsOneWidget);
      FilledButton confirm() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmar'),
      );
      expect(confirm().onPressed, isNull);
      final right = _requested(tester, code);
      final wrong = right[0] == 'A'
          ? 'B${right.substring(1)}'
          : 'A${right.substring(1)}';
      await _enterConfirm(tester, wrong);
      expect(confirm().onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no coinciden'), findsOneWidget);
      expect(find.text('Confirma tu código'), findsOneWidget);
      expect(await auth.isOnboardingPending(), isTrue);

      // Acierta (en minúsculas y con espacios también vale).
      await _enterConfirm(tester, right.toLowerCase());
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await _settle(tester);

      // El código ya no vuelve a mostrarse y la bandera se borró.
      expect(await auth.isOnboardingPending(), isFalse);
      expect(find.byKey(const ValueKey('recovery-code-box')), findsNothing);

      // 5) Biometría.
      expect(find.text('Desbloqueo biométrico'), findsOneWidget);
      await tester.tap(find.text('Activar'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await _settle(tester);
      expect(await auth.isBiometricUnlockEnabled(), isTrue);

      // 6) Drive: advertencia y conexión.
      expect(find.text('Respaldo en Google Drive'), findsOneWidget);
      expect(find.textContaining('perderás tus archivos'), findsOneWidget);
      await tester.tap(find.text('Conectar Google Drive'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('drive-connected')), findsOneWidget);
      expect(env.cloud.currentAccountEmail, isNotNull);

      // Entrar a la bóveda.
      await tester.tap(find.text('Entrar a mi bóveda'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeVaultScreen), findsOneWidget);
      expect(auth.isUnlocked, isTrue);
    });

    testWidgets(
      'sin biometría disponible y "Más tarde" en Drive: entra igual',
      (tester) async {
        usePhoneSize(tester);
        final env = _Env();
        env.bio.available = BiometricAvailability.notEnrolled;
        final auth = env.newAuth();
        await tester.pumpWidget(env.app(auth));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Empezar'));
        await tester.pumpAndSettle();
        await _createPin(tester);
        final code = _shownCode(tester);
        await tester.tap(find.text('Ya lo anoté'));
        await tester.pumpAndSettle();
        await _enterConfirm(tester, _requested(tester, code));
        await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
        await _settle(tester);

        // Se omite la biometría y se ofrece Drive con el aviso.
        expect(find.text('Desbloqueo biométrico'), findsNothing);
        expect(find.text('Respaldo en Google Drive'), findsOneWidget);
        expect(find.textContaining('Sin respaldo'), findsOneWidget);
        await tester.tap(find.text('Más tarde'));
        await tester.pumpAndSettle();
        expect(find.byType(HomeVaultScreen), findsOneWidget);
        expect(env.cloud.currentAccountEmail, isNull);
      },
    );

    testWidgets('"Ver código otra vez" vuelve a mostrar el código y no deja '
        'saltarse la confirmación', (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      final auth = env.newAuth();
      await tester.pumpWidget(env.app(auth));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empezar'));
      await tester.pumpAndSettle();
      await _createPin(tester);
      final code = _shownCode(tester);
      await tester.tap(find.text('Ya lo anoté'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ver código otra vez'));
      await tester.pumpAndSettle();
      expect(_shownCode(tester), code);
      expect(find.byType(HomeVaultScreen), findsNothing);
      expect(await auth.isOnboardingPending(), isTrue);
    });
  });

  group('Onboarding: reapertura a mitad', () {
    testWidgets('mismo proceso (bloqueo por segundo plano): vuelve al PIN y '
        'luego al MISMO código sin saltarse la confirmación', (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      final auth = env.newAuth();
      await tester.pumpWidget(env.app(auth, delay: AutoLockDelay.immediate));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empezar'));
      await tester.pumpAndSettle();
      await _createPin(tester);
      final code = _shownCode(tester);

      // Segundo plano con autobloqueo inmediato.
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.isUnlocked, isFalse);
      expect(find.text('Ingresa tu PIN maestro'), findsOneWidget);

      await _digits(tester, pin);
      await _crypto(tester);
      await _settle(tester);

      // De vuelta al paso del código, con el mismo código, sin entrar a la bóveda.
      expect(find.byType(HomeVaultScreen), findsNothing);
      expect(find.text('Tu código de recuperación'), findsOneWidget);
      expect(_shownCode(tester), code);
      expect(await auth.isOnboardingPending(), isTrue);
    });

    testWidgets('proceso muerto: reabre con PIN y ofrece GENERAR un código '
        'nuevo; hay que confirmarlo para entrar', (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      env.bio.available = BiometricAvailability.unavailable;
      // Sesión anterior: bóveda creada, onboarding sin confirmar, app muerta.
      final first = env.newAuth();
      final created = await first.createVault(pin, onboardingPending: true);
      final oldBackup = (await first.exportRecoveryBackup())!;
      first.lock();

      final auth = env.newAuth(); // proceso nuevo, sin el código en memoria
      await tester.pumpWidget(env.app(auth));
      await tester.pumpAndSettle();
      expect(find.text('Ingresa tu PIN maestro'), findsOneWidget);
      await _digits(tester, pin);
      await _crypto(tester);
      await _settle(tester);

      // No entra a la bóveda: pide generar un código nuevo.
      expect(find.byType(HomeVaultScreen), findsNothing);
      expect(find.text('Falta tu código de recuperación'), findsOneWidget);
      expect(find.byKey(const ValueKey('recovery-code-box')), findsNothing);
      await tester.tap(find.text('Generar nuevo código'));
      await tester.pumpAndSettle();

      // Pide el PIN (primero uno incorrecto).
      expect(find.text('Confirma tu PIN'), findsOneWidget);
      await _digits(tester, '135700');
      await _crypto(tester);
      expect(find.text('PIN incorrecto'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await _digits(tester, pin);
      await _crypto(tester);
      await _settle(tester);

      // Código nuevo, distinto del anterior, y el viejo ya no sirve.
      expect(find.text('Tu código de recuperación'), findsOneWidget);
      final fresh = _shownCode(tester);
      expect(fresh, isNot(created.recoveryCode));
      final newBackup = (await auth.exportRecoveryBackup())!;
      expect(newBackup, isNot(oldBackup));
      final other = AuthController(
        storage: InMemorySecureStore(),
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: VaultSession.create(),
      );
      expect(
        await other.restoreFromRecovery(
          recoveryCode: created.recoveryCode,
          recoveryBackupJson: newBackup,
          newPin: '135790',
        ),
        isFalse,
      );

      // Confirmarlo completa el onboarding (Drive y entrar).
      await tester.tap(find.text('Ya lo anoté'));
      await tester.pumpAndSettle();
      await _enterConfirm(tester, _requested(tester, fresh));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await _settle(tester);
      expect(await auth.isOnboardingPending(), isFalse);
      await tester.tap(find.text('Más tarde'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeVaultScreen), findsOneWidget);
    });

    testWidgets('onboarding terminado: al reabrir va directo a la bóveda y no '
        'se vuelve a mostrar ningún código', (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      final first = env.newAuth();
      await first.createVault(pin, onboardingPending: true);
      await first.completeOnboarding();
      first.lock();

      final auth = env.newAuth();
      await tester.pumpWidget(env.app(auth));
      await tester.pumpAndSettle();
      await _digits(tester, pin);
      await _crypto(tester);
      await _settle(tester);
      expect(find.byType(HomeVaultScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('recovery-code-box')), findsNothing);
    });
  });

  group('Paso "Confirma tu código" (posiciones reproducibles)', () {
    Future<List<bool>> pumpFlow(WidgetTester tester, {Random? random}) async {
      usePhoneSize(tester);
      final confirmed = <bool>[];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: RecoveryCodeFlow(
              code: _code,
              random: random ?? Random(3),
              onConfirmed: () => confirmed.add(true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ya lo anoté'));
      await tester.pumpAndSettle();
      return confirmed;
    }

    String expectedChars(Random r) {
      final ch = RecoveryCodeChallenge.generate(_code, random: r);
      final n = RecoveryCode.normalize(_code)!;
      return [for (final p in ch.positions) n[p - 1]].join();
    }

    testWidgets('muestra las posiciones del Random inyectado', (tester) async {
      await pumpFlow(tester);
      final ch = RecoveryCodeChallenge.generate(_code, random: Random(3));
      expect(
        find.textContaining('Escribe los caracteres ${ch.positionsLabel}'),
        findsOneWidget,
      );
    });

    testWidgets('acierto: llama a onConfirmed (una vez)', (tester) async {
      final confirmed = await pumpFlow(tester);
      await _enterConfirm(tester, expectedChars(Random(3)));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await tester.pumpAndSettle();
      expect(confirmed, hasLength(1));
    });

    testWidgets('errores: no confirma, muestra el error y vacía el campo', (
      tester,
    ) async {
      final confirmed = await pumpFlow(tester);
      final right = expectedChars(Random(3));
      final wrong = right.split('').reversed.join() == right
          ? 'ZZZZ'
          : right.split('').reversed.join();
      await _enterConfirm(tester, wrong);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await tester.pumpAndSettle();
      expect(confirmed, isEmpty);
      expect(find.textContaining('no coinciden'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('confirm-code-field')),
      );
      expect(field.controller!.text, isEmpty);

      // Escribir de nuevo quita el error y ahora acierta.
      await _enterConfirm(tester, right);
      expect(find.textContaining('no coinciden'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await tester.pumpAndSettle();
      expect(confirmed, hasLength(1));
    });

    testWidgets('incompleto: el botón está deshabilitado', (tester) async {
      final confirmed = await pumpFlow(tester);
      final right = expectedChars(Random(3));
      await _enterConfirm(tester, right.substring(0, 3));
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmar'),
      );
      expect(button.onPressed, isNull);
      expect(confirmed, isEmpty);
    });

    testWidgets('el campo solo admite 4 caracteres alfanuméricos en '
        'mayúsculas', (tester) async {
      await pumpFlow(tester);
      await _enterConfirm(tester, 'ab-c d9xyz');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('confirm-code-field')),
      );
      expect(field.controller!.text, 'ABCD');
    });

    testWidgets('"Ver código otra vez" muestra el código y al volver se '
        'sortean posiciones nuevas', (tester) async {
      final confirmed = await pumpFlow(tester);
      final rng = Random(3);
      final first = RecoveryCodeChallenge.generate(_code, random: rng);
      final second = RecoveryCodeChallenge.generate(_code, random: rng);
      await tester.tap(find.text('Ver código otra vez'));
      await tester.pumpAndSettle();
      expect(find.text('Tu código de recuperación'), findsOneWidget);
      expect(_shownCode(tester), _code);
      await tester.tap(find.text('Ya lo anoté'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Escribe los caracteres ${second.positionsLabel}'),
        findsOneWidget,
      );
      expect(second.positions, isNot(first.positions));
      expect(confirmed, isEmpty);
    });
  });
}
