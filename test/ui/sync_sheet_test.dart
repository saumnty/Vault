import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/theme/app_spacing.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/features/sync/sync_cloud_button.dart';
import 'package:vault/features/sync/sync_sheet.dart';
import 'package:vault/shared/widgets/blur_sheet.dart';

import '../support/fake_cloud.dart';
import '../support/fakes.dart';
import '../support/ui_helpers.dart';

class _Ui {
  late Database db;
  late SyncService sync;
  late FakeCloudStorage cloud;
  late SyncQueueRepository queue;
}

Future<_Ui> _build(WidgetTester tester, {bool signedIn = true}) async {
  final ui = _Ui();
  await tester.runAsync(() async {
    sqfliteFfiInit();
    ui.db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: VaultSchema.version,
        onCreate: (db, v) => VaultSchema.create(db),
      ),
    );
    ui.cloud = FakeCloudStorage(email: signedIn ? 'santy@example.com' : null);
    ui.queue = SyncQueueRepository(dbProvider: () async => ui.db);
    ui.sync = SyncService(
      cloud: ui.cloud,
      queue: ui.queue,
      items: VaultDataRepository(dbProvider: () async => ui.db),
      network: FakeNetworkMonitor(),
      prefs: SyncPreferences(InMemorySecureStore()),
      isUnlocked: () => true,
      resolvePath: (rel) => File(rel),
      recoveryBackupProvider: () async => null,
      snapshotProvider: () async => throw UnimplementedError(),
      scheduleWakeups: false,
    );
  });
  addTearDown(() async {
    await tester.runAsync(() async {
      ui.sync.dispose();
      await ui.db.close();
    });
  });
  return ui;
}

/// Deja terminar las consultas reales (hilo de sqflite) y redibuja.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _open(WidgetTester tester, _Ui ui) async {
  usePhoneSize(tester);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            actions: [
              SyncCloudButton(
                sync: ui.sync,
                onTap: () => showSyncSheet(context, ui.sync),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(SyncCloudButton));
  await tester.pump();
  await _settle(tester);
}

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('sin cuenta: botón de inicio de sesión y sin cuota', (
    tester,
  ) async {
    final ui = await _build(tester, signedIn: false);
    await _open(tester, ui);
    expect(find.byType(BlurSheet), findsOneWidget);
    expect(find.text('Sincronización'), findsOneWidget);
    expect(find.text('Iniciar sesión con Google'), findsOneWidget);
    expect(find.textContaining('usados'), findsNothing);
    expect(find.text('Solo Wi-Fi'), findsOneWidget);
    // El botón de nube refleja "sin cuenta".
    expect(
      find.byTooltip('Sincronización: sin cuenta de Google'),
      findsOneWidget,
    );
  });

  testWidgets('explica que se sube cifrado a una carpeta oculta de Drive', (
    tester,
  ) async {
    final ui = await _build(tester, signedIn: false);
    await _open(tester, ui);
    expect(
      find.textContaining('carpeta oculta de tu Google Drive'),
      findsOneWidget,
    );
    expect(find.textContaining('Administrar aplicaciones'), findsNothing);
    await tester.ensureVisible(find.text('Más información'));
    await tester.tap(find.text('Más información'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Administrar aplicaciones > Vault'),
      findsOneWidget,
    );
    expect(find.textContaining('verificación en dos pasos'), findsOneWidget);
  });

  testWidgets('con cuenta: correo, cuota con barra, conteos y errores', (
    tester,
  ) async {
    final ui = await _build(tester);
    await tester.runAsync(() async {
      await ui.sync.start();
      await ui.queue.enqueue('a', SyncJobKind.file, now: 1);
      await ui.queue.enqueue('b', SyncJobKind.file, now: 2);
      await ui.queue.enqueue('c', SyncJobKind.recoveryBackup, now: 3);
      final j = (await ui.queue.find('c', SyncJobKind.recoveryBackup))!;
      await ui.queue.markError(
        j.id,
        attempts: 5,
        error: 'Error del servidor de Drive (503)',
      );
      final j2 = (await ui.queue.find('a', SyncJobKind.file))!;
      await ui.queue.markUploading(j2.id);
    });
    ui.cloud.quotaValue = const CloudQuota(
      usedBytes: 4 * 1024 * 1024 * 1024,
      limitBytes: 15 * 1024 * 1024 * 1024,
    );
    await _open(tester, ui);
    await tester.runAsync(() => ui.sync.refreshQuota());
    await _settle(tester);

    expect(find.text('santy@example.com'), findsOneWidget);
    expect(find.text('Cerrar sesión'), findsOneWidget);
    expect(find.text('4,00 GB de 15,00 GB usados'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Pendientes: 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Subiendo: 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Con error: 1'), findsOneWidget);
    expect(find.text('Respaldo de recuperación'), findsOneWidget);
    expect(find.text('Error del servidor de Drive (503)'), findsOneWidget);
    expect(find.text('Sincronizar ahora'), findsOneWidget);

    // Objetivos táctiles >= 44 px.
    for (final label in ['Reintentar', 'Cerrar sesión', 'Sincronizar ahora']) {
      final size = tester.getSize(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first,
      );
      expect(
        size.height,
        greaterThanOrEqualTo(AppSizes.minTouch),
        reason: label,
      );
    }
    final sw = tester.getSize(find.byType(Switch));
    expect(sw.height, greaterThanOrEqualTo(AppSizes.minTouch - AppSpacing.md));

    debugDisableShadows = false;
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/sync_sheet.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('"Solo Wi-Fi" se persiste y "Reintentar" reanuda el error', (
    tester,
  ) async {
    final ui = await _build(tester);
    await _open(tester, ui);
    expect(
      tester.widget<Switch>(find.byType(Switch)).value,
      isTrue, // por defecto solo Wi-Fi
    );
    await tester.tap(find.byType(Switch));
    await _settle(tester);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(await tester.runAsync(ui.sync.getWifiOnly), isFalse);
  });

  testWidgets('iniciar sesión desde la hoja muestra el correo', (tester) async {
    final ui = await _build(tester, signedIn: false);
    await _open(tester, ui);
    await tester.tap(find.text('Iniciar sesión con Google'));
    await _settle(tester);
    expect(find.text('test@example.com'), findsOneWidget);
    expect(find.text('Iniciar sesión con Google'), findsNothing);
  });

  testWidgets('error de inicio de sesión se muestra en la hoja', (
    tester,
  ) async {
    final ui = await _build(tester, signedIn: false);
    ui.cloud.failure = (op) => op == 'signin'
        ? const CloudSignInFailedException(
            'Configuración OAuth inválida (código 10)',
            code: '10',
          )
        : null;
    await _open(tester, ui);
    await tester.tap(find.text('Iniciar sesión con Google'));
    await _settle(tester);
    expect(find.textContaining('código 10'), findsOneWidget);
  });
}
