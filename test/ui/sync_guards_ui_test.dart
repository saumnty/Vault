// D78 (cambio de cuenta atascado, parte B, puntos 3 y 4): Ajustes y la hoja
// de la cuadrícula con las mismas guardas y sin fallos silenciosos, y el
// aviso de la nube en la cuadrícula por prioridades.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/cloud_verification_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/features/settings/widgets/settings_widgets.dart';
import 'package:vault/features/sync/cloud_status_banner.dart';
import 'package:vault/features/sync/sync_cloud_button.dart';
import 'package:vault/features/sync/sync_sheet.dart';
import 'package:vault/shared/vault_ui_mode.dart';

import '../support/fake_cloud.dart';
import '../support/fakes.dart';
import '../support/settings_support.dart';
import '../support/ui_helpers.dart';

// ------------------------------------------------------------ hoja / banner

class _Ui {
  late Database db;
  late SyncService sync;
  late FakeCloudStorage cloud;
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
    ui.sync = SyncService(
      cloud: ui.cloud,
      queue: SyncQueueRepository(dbProvider: () async => ui.db),
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Cambia una pausa (refresca conteos con consultas reales de sqflite).
Future<void> _pause(WidgetTester tester, void Function() set) async {
  await tester.runAsync(() async {
    set();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

const _stuck = MigrationStatus(
  phase: MigrationPhase.signInNew,
  oldEmail: 'pruebas@example.com',
);

SyncSummary _s({
  String? email = 'a@b.c',
  SyncPauseReason? pause,
  CloudCopyCounts cloud = const CloudCopyCounts(),
  SyncPhase phase = SyncPhase.idle,
}) => SyncSummary(
  accountEmail: email,
  pauseReason: pause,
  cloud: cloud,
  phase: phase,
);

/// D70: nada de la nube (ni correos) en estos textos.
void _noPersonal(CloudBannerState s) {
  final all = '${s.title} ${s.detail ?? ''}';
  expect(all.contains('@'), isFalse, reason: all);
}

void main() {
  setUpAll(loadGoldenFonts);

  group('aviso de la nube: prioridades (cloudBannerFor)', () {
    test('nada que avisar cuando de verdad está al día', () {
      expect(
        cloudBannerFor(summary: _s(cloud: const CloudCopyCounts(total: 3))),
        isNull,
      );
    });

    test('el cambio de cuenta va primero (también con rotación)', () {
      final st = cloudBannerFor(
        summary: _s(
          pause: SyncPauseReason.migration,
          cloud: const CloudCopyCounts(total: 2, unverified: 2, noCopy: 1),
        ),
        migration: _stuck,
        rotating: true,
      )!;
      expect(st.kind, CloudBannerKind.migration);
      expect(st.action, 'Ver');
      _noPersonal(st);
    });

    test('con una rotación, su propio aviso (este no se muestra)', () {
      expect(
        cloudBannerFor(
          summary: _s(cloud: const CloudCopyCounts(total: 2, unverified: 2)),
          rotating: true,
        ),
        isNull,
      );
    });

    test('verificando > sin copia > sin cuenta > sin comprobar > solo en '
        'el teléfono > en pausa', () {
      const all = CloudCopyCounts(
        total: 9,
        localOnly: 2,
        unverified: 3,
        noCopy: 1,
      );
      expect(
        cloudBannerFor(
          summary: _s(cloud: all),
          verification: const CloudVerificationProgress(1, 4),
        )!.title,
        'Comprobando tu copia en la nube… 1/4',
      );
      expect(
        cloudBannerFor(summary: _s(cloud: all))!.kind,
        CloudBannerKind.noCopy,
      );
      expect(
        cloudBannerFor(
          summary: _s(
            email: null,
            cloud: const CloudCopyCounts(total: 9, unverified: 9),
          ),
        )!.kind,
        CloudBannerKind.noAccount,
      );
      final unv = cloudBannerFor(
        summary: _s(
          cloud: const CloudCopyCounts(total: 9, localOnly: 2, unverified: 3),
        ),
      )!;
      expect(unv.kind, CloudBannerKind.unverified);
      expect(unv.title, 'Tus archivos no tienen copia en la nube');
      expect(unv.action, 'Verificar copia');
      final local = cloudBannerFor(
        summary: _s(
          pause: SyncPauseReason.rotationMaintenance,
          cloud: const CloudCopyCounts(total: 9, localOnly: 2),
        ),
      )!;
      expect(local.kind, CloudBannerKind.localOnly);
      expect(local.detail, contains('En pausa'));
      expect(
        cloudBannerFor(
          summary: _s(
            pause: SyncPauseReason.rotationMaintenance,
            cloud: const CloudCopyCounts(total: 9),
          ),
        )!.kind,
        CloudBannerKind.paused,
      );
    });
  });

  group('CloudStatusBanner (widget)', () {
    testWidgets('«Tus archivos no tienen copia en la nube» con «Verificar '
        'copia»; nada en la adicional', (tester) async {
      final ui = await _build(tester);
      var verified = 0;
      await tester.runAsync(() async {
        await ui.db.insert('vault_items', {
          'id': 'a',
          'name': 'a.jpg',
          'encryptedPath': 'vault/a.vault',
          'fileSize': 1,
          'createdAt': '2026-01-01',
          'syncStatus': 'en_nube',
          'driveFileId': 'remoto',
        });
        await ui.sync.refreshCounts();
      });
      // Sin proveedor de tags (pruebas antiguas) no hay «sin comprobar»: se
      // fuerza el conteo como lo dejaría la app con tags.
      ui.sync.summary.value = ui.sync.summary.value.copyWith(
        cloud: const CloudCopyCounts(total: 1, unverified: 1),
      );
      Widget app() => testApp(
        Scaffold(
          body: CloudStatusBanner(
            sync: ui.sync,
            onVerify: () => verified++,
          ),
        ),
      );
      await tester.pumpWidget(app());
      expect(
        find.byKey(const ValueKey('cloud-banner-unverified')),
        findsOneWidget,
      );
      expect(
        find.text('Tus archivos no tienen copia en la nube'),
        findsOneWidget,
      );
      await tester.tap(find.text('Verificar copia'));
      expect(verified, 1);
      // El icono de la barra tampoco dice «al día».
      expect(syncSummaryLabel(ui.sync.summary.value), contains('sin comprobar'));

      VaultUiMode.cloudless = true;
      addTearDown(() => VaultUiMode.cloudless = false);
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.byType(Material).evaluate().length, greaterThan(0));
      expect(find.text('Tus archivos no tienen copia en la nube'), findsNothing);
    });

    testWidgets('cambio de cuenta: «Ver» abre su pantalla', (tester) async {
      final ui = await _build(tester);
      final st = ValueNotifier<MigrationStatus>(_stuck);
      var opened = 0;
      await _pause(tester, () => ui.sync.pausedForMigration = true);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: CloudStatusBanner(
              sync: ui.sync,
              migration: st,
              onOpenMigration: () => opened++,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('cloud-banner-migration')),
        findsOneWidget,
      );
      await tester.tap(find.text('Ver'));
      expect(opened, 1);
      st.value = const MigrationStatus();
      await _pause(tester, () => ui.sync.pausedForMigration = false);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('cloud-banner-migration')),
        findsNothing,
      );
    });
  });

  group('hoja de Sincronización: mismas guardas que Ajustes', () {
    Future<void> openSheet(
      WidgetTester tester,
      _Ui ui, {
      ValueListenable<MigrationStatus>? migration,
      VoidCallback? onOpenMigration,
    }) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSyncSheet(
                    context,
                    ui.sync,
                    migration: migration,
                    onOpenMigration: onOpenMigration,
                  ),
                  child: const Text('abrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await _settle(tester);
    }

    testWidgets('durante un cambio de cuenta «Cerrar sesión» lleva a su '
        'pantalla y NO cierra la sesión', (tester) async {
      final ui = await _build(tester);
      ui.sync.pausedForMigration = true;
      var opened = 0;
      await openSheet(
        tester,
        ui,
        migration: ValueNotifier(_stuck),
        onOpenMigration: () => opened++,
      );
      expect(find.text('En pausa: hay un cambio de cuenta sin terminar.'),
          findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('sync-sheet-sign-out')),
      );
      await tester.tap(find.byKey(const ValueKey('sync-sheet-sign-out')));
      await _settle(tester);
      expect(opened, 1);
      expect(ui.cloud.currentAccountEmail, 'santy@example.com');
    });

    testWidgets('durante un cambio de cuenta «Iniciar sesión» también lleva '
        'a su pantalla', (tester) async {
      final ui = await _build(tester, signedIn: false);
      ui.sync.pausedForMigration = true;
      var opened = 0;
      await openSheet(
        tester,
        ui,
        migration: ValueNotifier(_stuck),
        onOpenMigration: () => opened++,
      );
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      expect(opened, 1);
      expect(ui.cloud.currentAccountEmail, isNull);
    });

    testWidgets('«Sincronizar ahora» en pausa dice por qué en la hoja', (
      tester,
    ) async {
      final ui = await _build(tester);
      ui.sync.pausedForVerification = true;
      await openSheet(tester, ui);
      await tester.ensureVisible(
        find.byKey(const ValueKey('sync-sheet-sync-now')),
      );
      await tester.tap(find.byKey(const ValueKey('sync-sheet-sync-now')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('sync-sheet-notice')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('sync-sheet-notice'))).data,
        'En pausa: se está comprobando tu copia en la nube.',
      );
    });
  });

  group('Ajustes', () {
    Future<SettingsTestEnv> open(WidgetTester tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(390 * 2, 3000 * 2);
      addTearDown(tester.view.reset);
      final e = SettingsTestEnv();
      await tester.runAsync(e.init);
      addTearDown(e.dispose);
      await tester.pumpWidget(e.screen());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      return e;
    }

    void expectNoSilentDisabledTile(WidgetTester tester) {
      for (final t in tester.widgetList<SettingsTile>(
        find.byType(SettingsTile),
      )) {
        if (t.onTap == null && t.trailing == null) {
          // Filas informativas (sin acción) llevan su texto; ninguna fila
          // con acción queda en gris sin decir por qué.
          expect(t.subtitle, isNotNull, reason: t.title);
        }
      }
    }

    testWidgets('«Sincronizar ahora» en pausa: subtítulo y SnackBar con el '
        'motivo; «Cerrar sesión» dice por qué', (tester) async {
      final e = await open(tester);
      expectNoSilentDisabledTile(tester);
      e.sync.pausedForMigration = true;
      await tester.pump();
      expect(
        find.text('En pausa: hay un cambio de cuenta sin terminar.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Sincronizar ahora'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Nunca en silencio: siempre hay una SnackBar con el resultado (este
      // entorno no tiene BD abierta, así que la pasada dice «bloqueada»).
      expect(find.byType(SnackBar), findsOneWidget);
      // El motivo de la pausa sigue en el subtítulo.
      expect(
        find.text('En pausa: hay un cambio de cuenta sin terminar.'),
        findsOneWidget,
      );
      expect(
        find.text('No disponible: termina o cancela el cambio de cuenta.'),
        findsOneWidget,
      );
      expectNoSilentDisabledTile(tester);
      await tester.tap(find.text('Cerrar sesión de Google'));
      await tester.pumpAndSettle();
      expect(find.text('Ahora no puedes cerrar sesión'), findsOneWidget);
      await tester.tap(find.text('Cerrar').last);
      await tester.pumpAndSettle();
      expect(e.sync.cloud.currentAccountEmail, isNotNull);
    });
  });
}
