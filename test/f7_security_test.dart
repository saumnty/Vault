import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/security/auto_lock.dart';
import 'package:vault/core/security/platform_security.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/main.dart';
import 'package:vault/shared/widgets/privacy_cover.dart';

import 'support/fakes.dart';
import 'support/ui_helpers.dart';

/// Relojes falsos (monotónico y de pared) que avanzan juntos.
class _Clocks {
  Duration mono = Duration.zero;
  DateTime wall = DateTime.utc(2026, 1, 1);
  late final AutoLockClock clock = AutoLockClock(
    monotonic: () => mono,
    wall: () => wall,
  );
  void advance(Duration d) {
    mono += d;
    wall = wall.add(d);
  }
}

/// Controlador con un contador de bloqueos y temporizador manual.
class _Harness {
  _Harness({AutoLockDelay delay = AutoLockDelay.seconds15}) {
    controller = AutoLockController(
      onLock: () => locks++,
      clock: clocks.clock,
      suspension: suspension,
      timerFactory: (d, cb) {
        timerDuration = d;
        timerCb = cb;
        return _FakeTimer();
      },
      initialDelay: delay,
    );
  }

  final clocks = _Clocks();
  final suspension = AutoLockSuspension();
  late final AutoLockController controller;
  int locks = 0;
  Duration? timerDuration;
  void Function()? timerCb;

  void go(AppLifecycleState s) => controller.didChangeAppLifecycleState(s);
  void background() {
    go(AppLifecycleState.inactive);
    go(AppLifecycleState.hidden);
    go(AppLifecycleState.paused);
  }

  void foreground() {
    go(AppLifecycleState.inactive);
    go(AppLifecycleState.resumed);
  }
}

/// Almacén que retiene la lectura de key_check (paso previo a abrir sesión).
class _GatedStore extends InMemorySecureStore {
  _GatedStore(this.gate);
  final Completer<void> gate;
  final Completer<void> reached = Completer<void>();
  bool gateKeyCheck = false;

  @override
  Future<String?> read(String key) async {
    if (gateKeyCheck && key == AuthController.keyCheckKey) {
      if (!reached.isCompleted) reached.complete();
      await gate.future;
    }
    return super.read(key);
  }
}

class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AutoLockController (reloj falso)', () {
    test('opciones y valor por defecto (1 minuto)', () {
      expect(AutoLockDelay.defaultValue, AutoLockDelay.minute1);
      expect(AutoLockDelay.values.map((d) => d.duration), [
        Duration.zero,
        const Duration(seconds: 15),
        const Duration(seconds: 30),
        const Duration(minutes: 1),
        const Duration(minutes: 5),
        const Duration(minutes: 15),
      ]);
      expect(AutoLockDelay.fromMillis(999), AutoLockDelay.minute1);
    });

    test('inmediato: bloquea al pasar a segundo plano', () {
      final h = _Harness(delay: AutoLockDelay.immediate);
      h.go(AppLifecycleState.inactive);
      expect(h.locks, 0, reason: 'inactive no cuenta');
      h.go(AppLifecycleState.hidden);
      expect(h.locks, 1);
      h.go(AppLifecycleState.paused);
      expect(h.locks, 1, reason: 'hidden -> paused no bloquea dos veces');
    });

    test('justo antes del umbral no bloquea; en el umbral sí', () {
      final a = _Harness();
      a.background();
      a.clocks.advance(
        const Duration(seconds: 15) - const Duration(milliseconds: 1),
      );
      a.foreground();
      expect(a.locks, 0);

      final b = _Harness();
      b.background();
      b.clocks.advance(const Duration(seconds: 15));
      b.foreground();
      expect(b.locks, 1);
    });

    test('varias pausas/reanudaciones: cada una cuenta desde su pausa', () {
      final h = _Harness();
      for (var i = 0; i < 5; i++) {
        h.background();
        h.clocks.advance(const Duration(seconds: 10));
        h.foreground();
      }
      expect(h.locks, 0, reason: '5 x 10 s sueltos no suman 15 s');
      h.background();
      h.clocks.advance(const Duration(seconds: 16));
      h.foreground();
      expect(h.locks, 1);
    });

    test('reanudar sin pausa previa no bloquea', () {
      final h = _Harness(delay: AutoLockDelay.immediate);
      h.foreground();
      expect(h.locks, 0);
    });

    test(
      'suspensión por diálogo del sistema: no bloquea ni cuenta mal',
      () async {
        final h = _Harness();
        final gate = Completer<void>();
        final f = h.suspension.run(() async {
          h.background(); // el prompt/permiso/selector pasa la app a segundo plano
          h.clocks.advance(const Duration(minutes: 20));
          await gate.future;
          h.foreground();
        });
        expect(h.suspension.isSuspended, isTrue);
        gate.complete();
        await f;
        expect(h.suspension.isSuspended, isFalse);
        expect(h.locks, 0, reason: 'ni al reanudar ni por temporizador');
        expect(h.controller.isArmed, isFalse);
        expect(h.timerCb, isNull);

        // Pasado el diálogo, un segundo plano normal sí cuenta desde cero.
        h.background();
        h.clocks.advance(const Duration(seconds: 15));
        h.foreground();
        expect(h.locks, 1);
      },
    );

    test('suspensión reentrante', () async {
      final s = AutoLockSuspension();
      await s.run(() async {
        await s.run(() async => expect(s.depth, 2));
        expect(s.isSuspended, isTrue);
      });
      expect(s.isSuspended, isFalse);
      await expectLater(
        s.run<void>(() async => throw StateError('x')),
        throwsStateError,
      );
      expect(s.isSuspended, isFalse, reason: 'se libera aunque falle');
    });

    test('temporizador en segundo plano bloquea; al volver no repite', () {
      final h = _Harness();
      h.background();
      expect(h.timerDuration, const Duration(seconds: 15));
      h.timerCb!();
      expect(h.locks, 1);
      h.clocks.advance(const Duration(minutes: 5));
      h.foreground();
      expect(h.locks, 1);
    });

    test(
      'reloj de pared hacia atrás no impide bloquear (gana el monotónico)',
      () {
        final h = _Harness();
        h.background();
        h.clocks.mono += const Duration(seconds: 20);
        h.clocks.wall = h.clocks.wall.subtract(const Duration(hours: 5));
        h.foreground();
        expect(h.locks, 1);
      },
    );

    test(
      'sueño del dispositivo (monotónico parado) lo cubre el reloj de pared',
      () {
        final h = _Harness();
        h.background();
        h.clocks.wall = h.clocks.wall.add(const Duration(minutes: 10));
        h.foreground();
        expect(h.locks, 1);
      },
    );

    test('preferencia persistida y recargada', () async {
      final store = InMemorySecureStore();
      final prefs = AutoLockPreferences(store);
      expect(await prefs.getDelay(), AutoLockDelay.minute1);
      final c1 = AutoLockController(onLock: () {}, preferences: prefs);
      await c1.setDelay(AutoLockDelay.minutes5);
      final c2 = AutoLockController(onLock: () {}, preferences: prefs);
      expect(c2.delay, AutoLockDelay.minute1);
      await c2.load();
      expect(c2.delay, AutoLockDelay.minutes5);
      store.data[AutoLockPreferences.delayKey] = 'basura';
      expect(await prefs.getDelay(), AutoLockDelay.minute1);
    });

    test('lockNow (manual) bloquea y desarma', () {
      final h = _Harness();
      h.background();
      h.controller.lockNow();
      expect(h.locks, 1);
      expect(h.controller.isArmed, isFalse);
    });
  });

  group('AuthController.lock cancela un desbloqueo en vuelo (regresión)', () {
    late AuthController c;
    late VaultSession session;

    setUp(() async {
      session = VaultSession.create();
      c = AuthController(
        storage: InMemorySecureStore(),
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: session,
      );
      await c.createVault('123456');
      c.lock();
    });

    test('PIN: lock durante el unlock => no abre la sesión', () async {
      final f = c.unlockWithPin('123456');
      final expectation = expectLater(
        f,
        throwsA(isA<UnlockCancelledException>()),
      );
      c.lock();
      await expectation;
      expect(session.isUnlocked, isFalse);
      // Un unlock nuevo después del bloqueo sí funciona.
      expect(await c.unlockWithPin('123456'), isTrue);
      expect(session.isUnlocked, isTrue);
    });

    test('PIN: lock a mitad de la apertura de sesión', () async {
      final gate = Completer<void>();
      final store = _GatedStore(gate);
      final s = VaultSession.create();
      final a = AuthController(
        storage: store,
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: s,
      );
      await a.createVault('123456');
      a.lock();
      store.gateKeyCheck = true;
      final f = a.unlockWithPin('123456');
      final expectation = expectLater(
        f,
        throwsA(isA<UnlockCancelledException>()),
      );
      await store
          .reached
          .future; // la derivación terminó; falta abrir la sesión
      a.lock();
      gate.complete();
      await expectation;
      expect(s.isUnlocked, isFalse);
    });

    test('mismo PIN tras el bloqueo no se fusiona con el cancelado', () async {
      final first = c.unlockWithPin('123456');
      final firstExpect = expectLater(
        first,
        throwsA(isA<UnlockCancelledException>()),
      );
      c.lock();
      final second = c.unlockWithPin('123456');
      await firstExpect;
      expect(await second, isTrue);
      expect(session.isUnlocked, isTrue);
    });

    test('biometría: lock durante el unlock', () async {
      final bio = FakeBiometricKeyStore();
      final store = InMemorySecureStore();
      final s = VaultSession.create();
      final a = AuthController(
        storage: store,
        biometricStore: bio,
        kdfParams: fastKdf,
        session: s,
      );
      await a.createVault('123456');
      await a.enableBiometricUnlock();
      a.lock();
      final f = a.unlockWithBiometrics();
      final expectation = expectLater(
        f,
        throwsA(isA<UnlockCancelledException>()),
      );
      a.lock();
      await expectation;
      expect(s.isUnlocked, isFalse);
      expect(await a.unlockWithBiometrics(), isTrue);
    });
  });

  group('Canal vault/security (mock)', () {
    final calls = <MethodCall>[];
    const channel = MethodChannel('vault/security');
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
            calls.add(c);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AppPaths.resetForTesting();
    });

    ScreenProtection protection(
      InMemorySecureStore store, {
      bool define = false,
      bool release = false,
    }) => ScreenProtection(
      preferences: ScreenProtectionPreferences(store),
      platform: PlatformSecurity(isAndroid: true, isIOS: false),
      allowScreenshotsDefine: define,
      releaseMode: release,
    );

    test('Proteger pantalla: activa por defecto; setSecure(true)', () async {
      final store = InMemorySecureStore();
      await protection(store).apply();
      expect(calls.single.method, 'setSecure');
      expect(calls.single.arguments, {'secure': true});
    });

    test('cambiar la preferencia persiste y reaplica', () async {
      final store = InMemorySecureStore();
      final p = protection(store);
      await p.setEnabled(false);
      expect(calls.last.arguments, {'secure': false});
      expect(await p.isEnabled(), isFalse);
      await p.setEnabled(true);
      expect(calls.last.arguments, {'secure': true});
      expect(calls, hasLength(2));
    });

    test(
      'define VAULT_ALLOW_SCREENSHOTS: apaga en debug, se ignora en release',
      () async {
        final store = InMemorySecureStore();
        await protection(store, define: true).apply();
        expect(calls.last.arguments, {'secure': false});
        calls.clear();
        await protection(store, define: true, release: true).apply();
        expect(calls.last.arguments, {'secure': true});
      },
    );

    test('en no-Android no se llama a setSecure', () async {
      await PlatformSecurity(isAndroid: false, isIOS: true).setSecure(true);
      expect(calls, isEmpty);
    });

    test(
      'iOS: excludeFromBackup con las rutas absolutas de AppPaths',
      () async {
        final base = await Directory.systemTemp.createTemp('f7_ios');
        addTearDown(() => base.delete(recursive: true));
        await AppPaths.init(baseDir: base);
        await PlatformSecurity(
          isAndroid: false,
          isIOS: true,
        ).excludeVaultFromBackup();
        expect(calls.single.method, 'excludeFromBackup');
        final paths = (calls.single.arguments as Map)['paths'] as List;
        expect(paths, [
          AppPaths.vaultDir.path,
          AppPaths.thumbsDir.path,
          AppPaths.dbDir.path,
          AppPaths.cacheDir.path,
        ]);
        for (final p in paths) {
          expect(Directory(p as String).existsSync(), isTrue);
        }
      },
    );

    test(
      'excludeFromBackup se repite en cada arranque; recrea carpetas',
      () async {
        final base = await Directory.systemTemp.createTemp('f7_ios2');
        addTearDown(() => base.delete(recursive: true));
        await AppPaths.init(baseDir: base);
        final sec = PlatformSecurity(isAndroid: false, isIOS: true);
        await sec.excludeVaultFromBackup();
        AppPaths.thumbsDir.deleteSync(recursive: true);
        await sec.excludeVaultFromBackup();
        expect(calls, hasLength(2));
        expect(AppPaths.thumbsDir.existsSync(), isTrue);
      },
    );

    test('en no-iOS NO se llama a excludeFromBackup', () async {
      final base = await Directory.systemTemp.createTemp('f7_and');
      addTearDown(() => base.delete(recursive: true));
      await AppPaths.init(baseDir: base);
      await PlatformSecurity(
        isAndroid: true,
        isIOS: false,
      ).excludeVaultFromBackup();
      expect(calls, isEmpty);
    });
  });

  group('Privacy cover', () {
    testWidgets('cubre en inactive/hidden/paused y no en resumed', (
      tester,
    ) async {
      for (final (s, covered) in [
        (AppLifecycleState.resumed, false),
        (AppLifecycleState.inactive, true),
        (AppLifecycleState.hidden, true),
        (AppLifecycleState.paused, true),
      ]) {
        await tester.pumpWidget(
          testApp(PrivacyCover(state: s, child: const Text('secreto'))),
        );
        expect(
          find.byKey(const ValueKey('privacy-cover')),
          covered ? findsOneWidget : findsNothing,
          reason: '$s',
        );
      }
    });

    testWidgets('sigue el ciclo de vida real', (tester) async {
      await tester.pumpWidget(testApp(const PrivacyCover(child: Text('x'))));
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
    });
  });

  group('Botón Bloquear ahora', () {
    testWidgets('semántica, tamaño >= 44 y callback', (tester) async {
      usePhoneSize(tester);
      var locked = 0;
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(FakeVaultRepository()),
            onLock: () => locked++,
          ),
        ),
      );
      await tester.pump();
      final btn = find.byKey(const ValueKey('lock-now'));
      expect(btn, findsOneWidget);
      expect(find.byTooltip('Bloquear ahora'), findsOneWidget);
      final size = tester.getSize(btn);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      await tester.tap(btn);
      expect(locked, 1);
    });

    testWidgets('sin onLock no se muestra', (tester) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(FakeVaultRepository()),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('lock-now')), findsNothing);
    });
  });

  group('App completa: autobloqueo y navegación', () {
    late _Clocks clocks;
    late AutoLockSuspension suspension;
    late VaultSession session;
    late AuthController auth;

    Future<void> openApp(WidgetTester tester, AutoLockDelay delay) async {
      usePhoneSize(tester);
      clocks = _Clocks();
      suspension = AutoLockSuspension();
      session = VaultSession.create();
      auth = AuthController(
        storage: InMemorySecureStore(),
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: session,
      );
      await tester.runAsync(() => auth.createVault('123456'));
      auth.lock();
      await tester.pumpWidget(
        VaultApp(
          authController: auth,
          services: fakeServices(FakeVaultRepository()),
          autoLockClock: clocks.clock,
          autoLockSuspension: suspension,
          autoLockDelay: delay,
        ),
      );
      await tester.pump(); // arranque: decide onboarding o PIN
      await tester.pumpAndSettle(); // monta y carga la pantalla de PIN
      for (final d in '123456'.split('')) {
        await tester.tap(find.bySemanticsLabel('Dígito $d'));
        await tester.pump();
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(HomeVaultScreen), findsOneWidget);
      expect(session.isUnlocked, isTrue);
    }

    void bg(WidgetTester tester) {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    void fg(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('volver antes del umbral: sigue desbloqueada', (tester) async {
      await openApp(tester, AutoLockDelay.seconds15);
      bg(tester);
      clocks.advance(const Duration(seconds: 5));
      fg(tester);
      await tester.pumpAndSettle();
      expect(find.byType(HomeVaultScreen), findsOneWidget);
      expect(session.isUnlocked, isTrue);
    });

    testWidgets(
      'volver después del umbral: bloquea, vuelve al PIN y limpia la pila',
      (tester) async {
        await openApp(tester, AutoLockDelay.seconds15);
        final ctx = tester.element(find.byType(HomeVaultScreen));
        // Pila: una ruta (visor) + un diálogo + una hoja encima.
        unawaited(
          Navigator.of(ctx).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('visor')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final ctx2 = tester.element(find.text('visor'));
        unawaited(
          showDialog<void>(
            context: ctx2,
            builder: (_) => const AlertDialog(content: Text('dialogo')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('dialogo'), findsOneWidget);

        bg(tester);
        clocks.advance(const Duration(seconds: 15));
        fg(tester);
        await tester.pumpAndSettle();

        expect(session.isUnlocked, isFalse);
        expect(find.byType(PinScreen), findsOneWidget);
        expect(find.byType(HomeVaultScreen), findsNothing);
        expect(find.text('visor'), findsNothing);
        expect(find.text('dialogo'), findsNothing);
        expect(
          Navigator.of(tester.element(find.byType(PinScreen))).canPop(),
          isFalse,
        );
      },
    );

    testWidgets('el temporizador bloquea con la app aún en segundo plano', (
      tester,
    ) async {
      await openApp(tester, AutoLockDelay.seconds15);
      bg(tester);
      await tester.pump(const Duration(seconds: 14));
      expect(session.isUnlocked, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(session.isUnlocked, isFalse);
      fg(tester);
      await tester.pumpAndSettle();
      expect(find.byType(PinScreen), findsOneWidget);
    });

    testWidgets('inmediato: bloquea al pasar a segundo plano', (tester) async {
      await openApp(tester, AutoLockDelay.immediate);
      bg(tester);
      expect(session.isUnlocked, isFalse);
      fg(tester);
      await tester.pumpAndSettle();
      expect(find.byType(PinScreen), findsOneWidget);
    });

    testWidgets('diálogo del sistema (suspensión) no bloquea', (tester) async {
      await openApp(tester, AutoLockDelay.immediate);
      final gate = Completer<void>();
      final f = suspension.run(() => gate.future);
      bg(tester);
      clocks.advance(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 30));
      fg(tester);
      gate.complete();
      await f;
      await tester.pumpAndSettle();
      expect(session.isUnlocked, isTrue);
      expect(find.byType(HomeVaultScreen), findsOneWidget);
    });

    testWidgets('Bloquear ahora cierra sesión y vuelve al PIN', (tester) async {
      await openApp(tester, AutoLockDelay.minutes15);
      await tester.tap(find.byKey(const ValueKey('lock-now')));
      await tester.pumpAndSettle();
      expect(session.isUnlocked, isFalse);
      expect(find.byType(PinScreen), findsOneWidget);
    });

    testWidgets('la cobertura de privacidad aparece al pasar a inactive', (
      tester,
    ) async {
      await openApp(tester, AutoLockDelay.minutes15);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
    });
  });
}
