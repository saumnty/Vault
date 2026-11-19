// Fase 8, paso 7 (DISENO_SENUELO §4.4): servicios PROPIOS de la bóveda
// secundaria y navegación recalculada por bóveda en cada desbloqueo (M7).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/session_hooks.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/main.dart';

import '../support/fakes.dart';
import '../support/ui_helpers.dart';

const _pinP = '111111';
const _pinS = '482913';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('VaultServices.secondary(): sin nube, sin _Core y con los ganchos de '
      'bloqueo instalados; una sola instancia', () {
    final before = VaultDataRepository.onDataChanged;
    final s = VaultServices.secondary();
    expect(identical(VaultServices.secondary(), s), isTrue);
    expect(s.isCloudless, isTrue);
    expect(s.sync, isNull);
    expect(s.storage, isNull);
    expect(s.migration, isNull);
    expect(s.rotation, isNull);
    expect(s.beforeLock, isNull);
    expect(s.cache, isNull);
    expect(s.remoteDeleter, isNull);
    expect(s.trash, isNotNull);
    expect(s.tags, isNotNull);
    expect(s.gallery, isNotNull);
    expect(s.mediaExporter, isNotNull);
    // No se creó el núcleo de la principal (que engancharía el snapshot).
    expect(VaultDataRepository.onDataChanged, same(before));
    expect(SessionHooks.isInstalled(VaultSession()), isTrue);
  });

  group('navegación por bóveda', () {
    late Directory base;
    late VaultSession session;
    late AuthController auth;
    late int primaryFlushes;
    late int primaryOpened;
    late int secondaryOpened;
    late VaultServices primary;
    late VaultServices secondary;

    Future<void> setUpVaults(WidgetTester tester) async {
      usePhoneSize(tester);
      await tester.runAsync(() async {
        base = await Directory.systemTemp.createTemp('nav_alt');
        await AppPaths.init(baseDir: base);
        session = VaultSession.create();
        auth = AuthController(
          storage: InMemorySecureStore(),
          biometricStore: FakeBiometricKeyStore(),
          kdfParams: fastKdf,
          session: session,
          excludeFromBackup: (_) async {},
        );
        await auth.createVault(_pinP);
        await auth.createSecondaryVault(primaryPin: _pinP, newPin: _pinS);
        auth.lock();
      });
      addTearDown(() async {
        AppPaths.resetForTesting();
        try {
          base.deleteSync(recursive: true);
        } catch (_) {}
      });
      primaryFlushes = 0;
      primaryOpened = 0;
      secondaryOpened = 0;
      VaultServices build(
        FakeVaultRepository repo, {
        Future<void> Function()? beforeLock,
        required Future<void> Function() onUnlocked,
      }) {
        final f = fakeServices(repo);
        return VaultServices(
          repository: f.repository,
          importFile: f.importFile,
          syncRunner: f.syncRunner,
          thumbnailLoader: f.thumbnailLoader,
          fileCleaner: f.fileCleaner,
          offlineToggler: f.offlineToggler,
          beforeLock: beforeLock,
          onUnlocked: onUnlocked,
        );
      }

      primary = build(
        FakeVaultRepository(),
        beforeLock: () async => primaryFlushes++,
        onUnlocked: () async => primaryOpened++,
      );
      secondary = build(
        FakeVaultRepository(),
        onUnlocked: () async => secondaryOpened++,
      );
      await tester.pumpWidget(
        VaultApp(
          authController: auth,
          services: primary,
          secondaryServices: secondary,
          autoLockDelay: AutoLockDelay.defaultValue,
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    Future<void> enter(WidgetTester tester, String pin) async {
      expect(find.byType(PinScreen), findsOneWidget);
      for (final d in pin.split('')) {
        await tester.tap(find.bySemanticsLabel('Dígito $d'));
        await tester.pump();
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    Future<void> lockNow(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('lock-now')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    HomeVaultScreen home(WidgetTester tester) =>
        tester.widget<HomeVaultScreen>(find.byType(HomeVaultScreen));

    testWidgets('principal → bloquear → secundaria → bloquear → principal: '
        'servicios y Ajustes de cada una; el flush solo en la principal', (
      tester,
    ) async {
      await setUpVaults(tester);

      await enter(tester, _pinP);
      expect(session.slot, VaultSlot.primary);
      expect(home(tester).services, same(primary));
      expect(home(tester).settings!.slot, VaultSlot.primary);
      expect(home(tester).key, const ValueKey('vault-primary'));
      await lockNow(tester);
      expect(primaryFlushes, 1);
      expect(session.isUnlocked, isFalse);

      await enter(tester, _pinS);
      expect(session.slot, VaultSlot.secondary);
      expect(home(tester).services, same(secondary));
      expect(home(tester).settings!.isSecondary, isTrue);
      expect(home(tester).key, const ValueKey('vault-secondary'));
      expect(secondaryOpened, greaterThan(0));
      await lockNow(tester);
      expect(primaryFlushes, 1, reason: 'la secundaria no hace flush');

      await enter(tester, _pinP);
      expect(session.slot, VaultSlot.primary);
      expect(home(tester).services, same(primary));
      expect(home(tester).settings!.isSecondary, isFalse);
      await lockNow(tester);
      expect(primaryFlushes, 2);
    });
  });
}
