// Fase 8, paso 8 (DISENO_SENUELO §6.11, §6.12, §7, G7, M8): Ajustes reducido
// y pantalla de la bóveda secundaria sin palabras que la delaten; en la
// principal, la bóveda adicional solo aparece en su fila de Ajustes.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';
import 'package:vault/features/settings/secondary_vault_screen.dart';
import 'package:vault/features/settings/settings_screen.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/services/trash_service.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';
import 'package:vault/features/vault/widgets/vault_sheets.dart';
import 'package:vault/data/trash/trash_repository.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/shared/vault_ui_mode.dart';

import '../support/settings_support.dart';
import '../support/ui_helpers.dart';

/// Palabras que NUNCA deben verse dentro de la bóveda secundaria (G7).
const List<String> forbidden = [
  'google',
  'drive',
  'nube',
  'código de recuperación',
  'llave maestra',
  'secundaria',
  'adicional',
  'principal',
  'face id',
  'huella',
  'biométric',
  'diagnóstico',
  'sincroniz',
  'sin conexión',
  'cambiar pin',
  'señuelo',
  '@',
];

/// Todo el texto visible y accesible del árbol actual.
List<String> visibleTexts(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byWidgetPredicate((_) => true).evaluate()) {
    final w = e.widget;
    if (w is Text) {
      out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    } else if (w is RichText) {
      out.add(w.text.toPlainText());
    } else if (w is Semantics) {
      out.add(w.properties.label ?? '');
      out.add(w.properties.hint ?? '');
      out.add(w.properties.value ?? '');
    } else if (w is Tooltip) {
      out.add(w.message ?? '');
    }
  }
  return out;
}

void expectNoForbidden(WidgetTester tester, {String where = ''}) {
  for (final t in visibleTexts(tester)) {
    final low = t.toLowerCase();
    for (final f in forbidden) {
      expect(low.contains(f), isFalse, reason: '$where: «$t» contiene «$f»');
    }
  }
}

void _tall(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 3000 * 2);
  addTearDown(tester.view.reset);
}

VaultServices _secondaryLike(FakeVaultRepository repo) {
  final f = fakeServices(repo);
  return VaultServices(
    repository: f.repository,
    importFile: f.importFile,
    syncRunner: f.syncRunner,
    thumbnailLoader: f.thumbnailLoader,
    fileCleaner: f.fileCleaner,
    offlineToggler: f.offlineToggler,
    trash: TrashService(
      repository: TrashRepository(dbProvider: () => throw StateError('x')),
      fileCleaner: (_) async {},
    ),
    tags: TagRepository(dbProvider: () => throw StateError('x')),
  );
}

void main() {
  tearDown(() => VaultUiMode.cloudless = false);

  group('dentro de la bóveda secundaria', () {
    testWidgets('Ajustes reducido: sin palabras prohibidas; solo lo neutro', (
      tester,
    ) async {
      _tall(tester);
      VaultUiMode.cloudless = true;
      final e = SettingsTestEnv();
      await tester.runAsync(e.init);
      addTearDown(e.dispose);
      await tester.pumpWidget(
        testApp(
          SettingsScreen(
            env: e.env.forSlot(VaultSlot.secondary),
            services: _secondaryLike(FakeVaultRepository()),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Autobloqueo'), findsOneWidget);
      expect(find.text('Bloquear ahora'), findsOneWidget);
      expect(find.text('Calidad de video por defecto'), findsOneWidget);
      expect(find.text('Etiquetas'), findsWidgets);
      expect(find.text('Papelera'), findsWidgets);
      expect(find.text('Acerca de'), findsOneWidget);
      for (final gone in [
        'Cambiar PIN',
        'Desbloqueo biométrico',
        'Proteger pantalla',
        'Generar nuevo código de recuperación',
        'Comprobar mi código',
        'Bóveda adicional',
        'Diagnóstico',
        'Sincronización y cuenta',
        'Borrar originales cuando estén en la nube',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expectNoForbidden(tester, where: 'Ajustes');
    });

    testWidgets(
      'la cuadrícula, la selección y el borrado no mencionan la nube',
      (tester) async {
        usePhoneSize(tester);
        VaultUiMode.cloudless = true;
        final repo = FakeVaultRepository(
          items: [
            for (final s in SyncStatus.values)
              fakeItem('i${s.index}', status: s, withThumb: false),
          ],
        );
        await tester.pumpWidget(
          testApp(
            HomeVaultScreen(
              currentFolderName: 'Mi Bóveda',
              services: _secondaryLike(repo),
              onLock: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expectNoForbidden(tester, where: 'cuadrícula');
        // Modo selección.
        await tester.longPress(find.bySemanticsLabel(RegExp('IMG_i0')));
        await tester.pumpAndSettle();
        expectNoForbidden(tester, where: 'selección');
        // Hojas de confirmación.
        final ctx = tester.element(find.byType(HomeVaultScreen));
        for (final trash in [true, false]) {
          final f = showConfirmDeleteSheet(
            ctx,
            count: 2,
            includesFolders: true,
            toTrash: trash,
          );
          await tester.pumpAndSettle();
          expectNoForbidden(tester, where: 'borrar (papelera=$trash)');
          Navigator.of(ctx).pop(false);
          await tester.pumpAndSettle();
          await f;
        }
      },
    );

    test('M8: errores al abrir un archivo con texto neutro', () {
      VaultUiMode.cloudless = true;
      for (final err in <Object>[
        const CloudSlotException(),
        const CloudNoNetworkException(),
        const CloudNotAuthenticatedException(),
        const CloudNotFoundException(),
        const VaultFetchUnavailableException(),
        const VaultFetchVerificationException('x'),
      ]) {
        final m = describeMediaError(err).message.toLowerCase();
        for (final f in forbidden) {
          expect(m.contains(f), isFalse, reason: '$err: $m');
        }
      }
      VaultUiMode.cloudless = false;
      expect(
        describeMediaError(const CloudNotFoundException()).message,
        contains('nube'),
        reason: 'la principal sigue igual',
      );
    });
  });

  group('en la principal', () {
    testWidgets('la bóveda adicional solo aparece en su fila de Ajustes', (
      tester,
    ) async {
      usePhoneSize(tester);
      final repo = FakeVaultRepository(items: [fakeItem('a')]);
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(repo),
            onLock: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final t in visibleTexts(tester)) {
        final low = t.toLowerCase();
        expect(low.contains('adicional'), isFalse, reason: t);
        expect(low.contains('secundaria'), isFalse, reason: t);
      }
    });

    testWidgets('Ajustes > Seguridad tiene la fila «Bóveda adicional»', (
      tester,
    ) async {
      _tall(tester);
      final e = SettingsTestEnv();
      await tester.runAsync(e.init);
      addTearDown(e.dispose);
      await tester.pumpWidget(e.screen());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('secondary-vault-tile')),
        findsOneWidget,
      );
      expect(find.text('Desactivada'), findsOneWidget);
      // Fuera de esa fila, nada la menciona.
      final mentions = visibleTexts(
        tester,
      ).where((t) => t.toLowerCase().contains('adicional')).toList();
      // (el texto de la fila y su etiqueta accesible)
      expect(mentions, isNotEmpty);
      expect(
        mentions.every((m) => m.startsWith('Bóveda adicional')),
        isTrue,
        reason: '$mentions',
      );
      for (final t in visibleTexts(tester)) {
        expect(t.toLowerCase().contains('secundaria'), isFalse, reason: t);
      }
    });
  });

  group('SecondaryVaultScreen', () {
    late Directory base;

    late SettingsTestEnv env;

    Future<AuthController> setUpAuth(WidgetTester tester) async {
      await tester.runAsync(() async {
        base = await Directory.systemTemp.createTemp('alt_ui');
        await AppPaths.init(baseDir: base);
        env = SettingsTestEnv();
        await env.init();
      });
      addTearDown(env.dispose);
      final auth = env.auth;
      addTearDown(() {
        AppPaths.resetForTesting();
        try {
          base.deleteSync(recursive: true);
        } catch (_) {}
      });
      return auth;
    }

    Future<void> open(WidgetTester tester, AuthController auth) async {
      await tester.pumpWidget(testApp(SecondaryVaultScreen(auth: auth)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('sin crear: explica qué protege y qué NO, avisa de que no hay '
        'copia ni código, y ofrece crear', (tester) async {
      _tall(tester);
      final auth = await setUpAuth(tester);
      await open(tester, auth);
      expect(find.text('Bóveda adicional'), findsOneWidget);
      expect(find.text('Desactivada'), findsOneWidget);
      expect(find.text('Crear bóveda adicional'), findsOneWidget);
      expect(find.text('Qué protege'), findsOneWidget);
      expect(find.text('Qué NO protege'), findsOneWidget);
      final warn = tester.widget<Text>(
        find.byKey(const ValueKey('secondary-no-backup')),
      );
      expect(warn.data, contains('NO se copia a Google Drive'));
      expect(warn.data, contains('código de recuperación'));
      for (final t in secondaryVaultDoesNotProtect) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('Eliminar bóveda adicional'), findsNothing);
    });

    testWidgets('activa: cambiar su PIN y eliminar; aviso de biometría', (
      tester,
    ) async {
      _tall(tester);
      final auth = await setUpAuth(tester);
      await tester.runAsync(() async {
        await auth.unlockWithPin(settingsTestPin);
        await auth.createSecondaryVault(
          primaryPin: settingsTestPin,
          newPin: '482913',
        );
        await auth.enableBiometricUnlock();
      });
      await open(tester, auth);
      expect(find.text('Activa'), findsOneWidget);
      expect(find.text('Cambiar su PIN'), findsOneWidget);
      expect(find.text('Eliminar bóveda adicional'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('secondary-bio-warning')),
        findsOneWidget,
      );
      // Eliminar pide confirmación (y luego el PIN principal).
      await tester.tap(find.text('Eliminar bóveda adicional'));
      await tester.pumpAndSettle();
      expect(find.text('¿Eliminar la bóveda adicional?'), findsOneWidget);
      expect(find.textContaining('No tiene copia en la nube'), findsOneWidget);
    });

    testWidgets('dañada: solo eliminar', (tester) async {
      _tall(tester);
      final auth = await setUpAuth(tester);
      await tester.runAsync(() async {
        await auth.unlockWithPin(settingsTestPin);
        await auth.createSecondaryVault(
          primaryPin: settingsTestPin,
          newPin: '482913',
        );
      });
      // Envoltura ilegible.
      env.store.data[AuthController.altPinEnvelopeKey] = 'basura';
      await open(tester, auth);
      expect(find.text('Dañada'), findsOneWidget);
      expect(find.text('Cambiar su PIN'), findsNothing);
      expect(find.text('Eliminar bóveda adicional'), findsOneWidget);
    });
  });
}
