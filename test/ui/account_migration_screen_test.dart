// Pantalla "Cambiar de cuenta de Google": hoja explicativa, estados de
// bloqueo y decisiones finales.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';
import 'package:vault/features/settings/account_migration_screen.dart';

import '../support/f9_env.dart';
import '../support/multi_account_cloud.dart';
import '../support/ui_helpers.dart';

void main() {
  late PhoneA a;
  late MultiAccountCloud cloud;

  AccountMigrationService service({int? freeBytes}) => AccountMigrationService(
    cloud: cloud,
    items: a.items,
    migration: MigrationRepository(dbProvider: () => a.vdb.database),
    queue: a.queue,
    sync: a.sync,
    fetcher: VaultFileFetcher(
      cloud: cloud,
      items: a.items,
      resolvePath: AppPaths.resolve,
    ),
    network: a.net,
    prefs: a.prefs,
    recoveryBackupProvider: a.auth.exportRecoveryBackup,
    resolvePath: AppPaths.resolve,
    freeSpace: () async => freeBytes,
    nowMs: () => a.now,
  );

  Future<void> boot(WidgetTester t) async {
    await t.runAsync(() async {
      cloud = MultiAccountCloud('vieja@example.com');
      a = PhoneA()..cloud = cloud;
      await a.setUp();
      await a.addItem('i1', 'Uno.jpg', realThumb: true);
      await a.addItem('i2', 'Dos.jpg', realThumb: true);
    });
    addTearDown(() => t.runAsync(a.tearDown));
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpScreen(WidgetTester t, AccountMigrationService s) async {
    usePhoneSize(t);
    t.view.physicalSize = const Size(780, 3200); // todo el contenido visible
    await t.pumpWidget(testApp(AccountMigrationScreen(service: s)));
    await settle(t);
  }

  testWidgets('hoja previa: explica el flujo, cuánto ocupa y permite empezar', (
    t,
  ) async {
    await boot(t);
    await pumpScreen(t, service(freeBytes: 10 * 1024 * 1024 * 1024));
    expect(find.text('Qué va a pasar'), findsOneWidget);
    expect(find.textContaining('cuenta NUEVA'), findsOneWidget);
    expect(find.textContaining('OTRA bóveda'), findsWidgets);
    expect(find.text('Antes de empezar'), findsOneWidget);
    expect(find.textContaining('Wi-Fi'), findsWidgets);
    expect(find.text('Archivos'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Ocupará en la cuenta nueva'), findsOneWidget);
    expect(find.textContaining('antes de subir nada'), findsOneWidget);
    final start = t.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Empezar'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('sin espacio en el teléfono: avisa y no deja empezar', (t) async {
    await boot(t);
    // Un item solo en la nube: hay que bajarlo.
    await t.runAsync(() async {
      AppPaths.resolve(AppPaths.vaultRelativePath('i1')).deleteSync();
      await a.items.setDriveFileId('i1', 'drive1');
    });
    await pumpScreen(t, service(freeBytes: 10));
    expect(find.textContaining('No hay espacio suficiente'), findsWidgets);
    final start = t.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Empezar'),
    );
    expect(start.onPressed, isNull);
  });

  Future<AccountMigrationService> inPhase(
    WidgetTester t,
    MigrationPhase phase, {
    String? error,
  }) async {
    final s = service();
    await t.runAsync(() async {
      final repo = MigrationRepository(dbProvider: () => a.vdb.database);
      await repo.begin(
        oldEmail: 'vieja@example.com',
        neededBytes: 1000,
        downloadTotal: 0,
        now: 1,
      );
      await repo.update(
        phase: phase,
        newEmail: 'nueva@example.com',
        lastError: error,
        now: 2,
      );
      await s.refresh();
    });
    return s;
  }

  testWidgets('cuenta nueva con otra bóveda: mensaje claro y salidas', (
    t,
  ) async {
    await boot(t);
    final s = await inPhase(t, MigrationPhase.blockedOtherVault);
    await pumpScreen(t, s);
    expect(find.text('La cuenta nueva ya tiene otra bóveda'), findsOneWidget);
    expect(find.textContaining('No se subió ni se borró nada'), findsOneWidget);
    expect(find.text('Elegir otra cuenta'), findsOneWidget);
    expect(find.text('Cancelar y volver a la cuenta anterior'), findsOneWidget);
    expect(
      find.textContaining('Cuenta anterior: vieja@example.com'),
      findsOneWidget,
    );
  });

  testWidgets('sin cuota en la cuenta nueva', (t) async {
    await boot(t);
    final s = await inPhase(t, MigrationPhase.blockedQuota);
    await pumpScreen(t, s);
    expect(find.text('La cuenta nueva no tiene espacio'), findsOneWidget);
    expect(find.textContaining('No se subió nada'), findsOneWidget);
  });

  testWidgets('pausa por error: muestra el mensaje y "Reanudar"', (t) async {
    await boot(t);
    final s = await inPhase(
      t,
      MigrationPhase.uploading,
      error: 'En pausa: sin conexión. Se reanudará al volver la red.',
    );
    await pumpScreen(t, s);
    expect(find.text('Subiendo a la cuenta nueva'), findsOneWidget);
    expect(find.textContaining('En pausa: sin conexión'), findsOneWidget);
    expect(find.text('Reanudar'), findsOneWidget);
    expect(find.byKey(const ValueKey('migration-progress')), findsOneWidget);
  });

  testWidgets('listo: borrar pide confirmación explícita y permanente', (
    t,
  ) async {
    await boot(t);
    final s = await inPhase(t, MigrationPhase.askDeleteOld);
    await pumpScreen(t, s);
    expect(find.text('Borrar datos de la cuenta anterior'), findsOneWidget);
    expect(find.text('Conservarlos'), findsOneWidget);
    // Al terminar no se ofrece cancelar.
    expect(find.textContaining('Cancelar y volver'), findsNothing);
    await t.tap(find.text('Borrar datos de la cuenta anterior'));
    await settle(t);
    expect(find.textContaining('PERMANENTE'), findsOneWidget);
    expect(find.text('Borrar permanentemente'), findsOneWidget);
    // "Ahora no": no se borra nada y se sigue en la decisión.
    await t.tap(find.text('Ahora no'));
    await settle(t);
    expect(find.text('Conservarlos'), findsOneWidget);
  });

  testWidgets('conservar termina el cambio y muestra "Listo"', (t) async {
    await boot(t);
    final s = await inPhase(t, MigrationPhase.askDeleteOld);
    await pumpScreen(t, s);
    await t.tap(find.text('Conservarlos'));
    await settle(t);
    expect(find.text('Listo'), findsOneWidget);
    expect(await t.runAsync(s.hasActive), isFalse);
  });
}
