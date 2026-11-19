// D76 (cambio de cuenta atascado, parte A paso 2): pantalla «Cambio de cuenta
// sin terminar» y el invariante «nunca un cambio de cuenta guardado sin
// pantalla a la vista» al abrir la bóveda. Solo nubes falsas.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/features/settings/unfinished_migration_screen.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/vault_services.dart';

import '../support/ui_helpers.dart';
import '../support/verification_env.dart';

void main() {
  late VerifyEnv env;

  Future<void> boot(WidgetTester t) async {
    await t.runAsync(() async {
      env = VerifyEnv();
      await env.setUp();
      await env.a.addItem('i1', 'Uno.jpg', realThumb: true);
      await env.a.addItem('i2', 'Dos.jpg', realThumb: true);
    });
    addTearDown(() => t.runAsync(env.tearDown));
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AccountMigrationService> stuck(
    WidgetTester t,
    MigrationPhase phase, {
    String? session = principal,
  }) async {
    final s = env.migration(wireVerification: false);
    await t.runAsync(() async {
      await env.repo.begin(
        oldEmail: pruebas,
        neededBytes: 1,
        downloadTotal: 0,
        now: 1,
      );
      await env.repo.update(phase: phase, newEmail: null, now: 2);
      if (session == null) {
        await env.cloud.signOut();
      } else {
        await env.switchTo(session);
      }
      await s.refresh();
    });
    return s;
  }

  Future<void> pumpScreen(WidgetTester t, AccountMigrationService s) async {
    usePhoneSize(t);
    t.view.physicalSize = const Size(780, 3200);
    await t.pumpWidget(
      testApp(
        UnfinishedMigrationScreen(
          service: s,
          unverifiedCount: env.verifier.unverifiedCount,
        ),
      ),
    );
    await settle(t);
  }

  testWidgets('muestra la fase, las dos cuentas (solo en pantalla) y las '
      'salidas', (t) async {
    await boot(t);
    await t.runAsync(() async {
      // Fotos «en la nube» con referencias de la cuenta de pruebas.
      for (final id in ['i1', 'i2']) {
        await env.a.items.setDriveFileId(id, 'drive-$id');
        final db = await env.a.vdb.database;
        await db.update('vault_items', {
          'syncStatus': 'en_nube',
        }, where: 'id = ?', whereArgs: [id]);
      }
    });
    final s = await stuck(t, MigrationPhase.signInNew);
    await pumpScreen(t, s);
    expect(find.text('Cambio de cuenta sin terminar'), findsOneWidget);
    expect(find.textContaining('Elegir la cuenta nueva'), findsOneWidget);
    expect(find.textContaining('Cuenta anterior: $pruebas'), findsOneWidget);
    expect(find.textContaining('Cuenta actual: $principal'), findsOneWidget);
    expect(find.textContaining('La sincronización está en pausa'), findsOneWidget);
    expect(find.textContaining('2 archivo(s) no tienen copia'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.text('Cancelar y quedarme en $principal'), findsOneWidget);
    expect(find.text('Volver a la cuenta anterior'), findsOneWidget);
  });

  testWidgets('Cancelar y quedarme: confirma, termina el cambio y quita la '
      'pausa (sin pedir ninguna cuenta)', (t) async {
    await boot(t);
    final s = await stuck(t, MigrationPhase.checkingNew);
    await pumpScreen(t, s);
    final calls = env.cloud.signInCalls;
    await t.tap(find.text('Cancelar y quedarme en $principal'));
    await settle(t);
    expect(find.text('¿Quedarte en esta cuenta?'), findsOneWidget);
    expect(find.textContaining('No se borra nada'), findsOneWidget);
    await t.tap(find.text('Quedarme en esta cuenta'));
    await settle(t);
    expect(await t.runAsync(s.hasActive), isFalse);
    expect(env.sync.pausedForMigration, isFalse);
    expect(env.cloud.signInCalls, calls);
  });

  testWidgets('sin sesión: el botón pide iniciar sesión primero', (t) async {
    await boot(t);
    final s = await stuck(t, MigrationPhase.signInNew, session: null);
    await pumpScreen(t, s);
    expect(find.text('Inicia sesión primero'), findsOneWidget);
    expect(find.textContaining('Cancelar y quedarme'), findsNothing);
    expect(find.textContaining('Cuenta actual: sin sesión'), findsOneWidget);
    env.cloud.signInQueue.add(principal);
    await t.tap(find.text('Inicia sesión primero'));
    await settle(t);
    expect(find.text('Cancelar y quedarme en $principal'), findsOneWidget);
  });

  testWidgets('fase desconocida: solo Cancelar y quedarme', (t) async {
    await boot(t);
    final s = env.migration(wireVerification: false);
    await t.runAsync(() async {
      final db = await env.a.vdb.database;
      await db.insert('migration_state', {
        'id': 1,
        'phase': 'fase_futura',
        'oldEmail': pruebas,
        'startedAt': 1,
        'updatedAt': 1,
      });
      await env.switchTo(principal);
      await s.refresh();
    });
    await pumpScreen(t, s);
    expect(find.textContaining('Estado desconocido'), findsOneWidget);
    expect(find.text('Continuar'), findsNothing);
    expect(find.text('Volver a la cuenta anterior'), findsNothing);
    expect(find.text('Cancelar y quedarme en $principal'), findsOneWidget);
  });

  group('invariante al abrir la bóveda: con un cambio guardado, la pantalla '
      'aparece en cada fase', () {
    for (final phase in [
      ...MigrationPhase.values.where((p) => p != MigrationPhase.unknown),
    ]) {
      for (final session in [principal, null]) {
        testWidgets('${phase.name} · ${session == null ? 'sin' : 'con'} '
            'sesión', (t) async {
          await boot(t);
          final s = await stuck(t, phase, session: session);
          // Arranque en frío: el estado se lee en la apertura.
          s.status.value = const MigrationStatus();
          var unlocked = 0;
          final services = VaultServices(
            repository: env.a.items,
            importFile: ({required folderId, required deleteOriginal}) async =>
                false,
            syncRunner: () async {},
            thumbnailLoader: (_) async => null,
            fileCleaner: (_) async {},
            offlineToggler: (_, _) async => false,
            migration: s,
            verification: env.verifier,
            onUnlocked: () async {
              unlocked++;
              await s.refresh();
            },
          );
          usePhoneSize(t);
          await t.pumpWidget(
            testApp(
              HomeVaultScreen(
                currentFolderName: 'Mi Bóveda',
                services: services,
              ),
            ),
          );
          await settle(t);
          expect(unlocked, 1);
          expect(find.text('Cambio de cuenta sin terminar'), findsOneWidget);
          // La pausa sigue (nada se reanudó solo).
          expect(env.sync.pausedForMigration, isTrue);
          expect(s.isRunning, isFalse);
        });
      }
    }
  });

  testWidgets('sin cambio de cuenta guardado no aparece nada', (t) async {
    await boot(t);
    final s = env.migration(wireVerification: false);
    final services = VaultServices(
      repository: env.a.items,
      importFile: ({required folderId, required deleteOriginal}) async => false,
      syncRunner: () async {},
      thumbnailLoader: (_) async => null,
      fileCleaner: (_) async {},
      offlineToggler: (_, _) async => false,
      migration: s,
      onUnlocked: () async {
        await s.refresh();
      },
    );
    usePhoneSize(t);
    await t.pumpWidget(
      testApp(HomeVaultScreen(currentFolderName: 'Mi Bóveda', services: services)),
    );
    await settle(t);
    expect(find.text('Cambio de cuenta sin terminar'), findsNothing);
  });
}
