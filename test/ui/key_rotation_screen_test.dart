import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/features/settings/key_rotation_screen.dart';

import '../support/fake_cloud.dart';
import '../support/settings_support.dart';
import '../support/ui_helpers.dart';

const _pin = settingsTestPin;

class _Env {
  _Env(this.e, this.service, this.repo, this.net);
  final SettingsTestEnv e;
  final KeyRotationService service;
  final NoDbRotationRepository repo;
  final FakeNetworkMonitor net;
  AuthController get auth => e.auth;
}

void _useTallPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 3000 * 2);
  addTearDown(tester.view.reset);
}

Future<_Env> _env(
  WidgetTester tester, {
  RotationPlan? plan,
  NetworkKind network = NetworkKind.none,
}) async {
  _useTallPhone(tester);
  final e = SettingsTestEnv();
  await tester.runAsync(e.init);
  addTearDown(e.dispose);
  final repo = NoDbRotationRepository();
  final net = FakeNetworkMonitor(network);
  final service = e.rotationService(network: net, repo: repo, plan: plan);
  await tester.runAsync(() => e.auth.unlockWithPin(_pin));
  return _Env(e, service, repo, net);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  // Sin pumpAndSettle: la barra indeterminada no se detiene nunca.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Espera las animaciones de hojas/rutas (con la barra animándose).
Future<void> _anim(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _open(
  WidgetTester tester,
  _Env env, {
  RotationReason reason = RotationReason.rotateKey,
}) async {
  await tester.pumpWidget(
    testApp(
      KeyRotationScreen(
        service: env.service,
        reason: reason,
        random: Random(3),
      ),
    ),
  );
  await _settle(tester);
}

/// Rotación preparada (fase `prepared`) sin pasar por la UI.
Future<String> _prepare(WidgetTester tester, _Env env) async =>
    (await tester.runAsync(
      () => env.auth.prepareRotation(
        _pin,
        toGen: 2,
        accountEmail: 'santy@example.com',
      ),
    ))!;

Future<void> _setPhase(
  WidgetTester tester,
  _Env env,
  RotationPhase phase, {
  RotationPhase? resume,
  String? error,
}) async {
  await tester.runAsync(() async {
    final rec = (await env.auth.rotationRecord())!;
    await env.auth.rotationStore.save(
      rec.copyWith(phase: phase, resumePhase: resume, lastError: error),
    );
  });
  await tester.pump();
}

Future<void> _digits(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.bySemanticsLabel('Dígito $d'));
    await tester.pump();
  }
}

Future<void> _submitPin(WidgetTester tester, String digits) async {
  await _digits(tester, digits);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
}

const _plan = RotationPlan(
  items: 12,
  uploadBytes: 30 * settingsMb,
  cloudOnlyBytes: 0,
  pendingUploads: 0,
  lostThumbnails: 0,
  quota: null,
  enoughDriveSpace: true,
  signedIn: true,
);

void main() {
  group('Hoja previa', () {
    testWidgets('explica qué pasa y qué hace falta; Empezar activo', (
      tester,
    ) async {
      final env = await _env(tester, plan: _plan);
      await _open(tester, env);
      expect(find.text('Rotar llave maestra'), findsOneWidget);
      expect(find.text('Qué va a pasar'), findsOneWidget);
      expect(find.text('Antes de empezar'), findsOneWidget);
      expect(find.textContaining('Wi-Fi'), findsOneWidget);
      expect(find.textContaining('primer plano'), findsOneWidget);
      expect(find.textContaining('doble de espacio'), findsOneWidget);
      expect(find.textContaining('no podrás cambiar el PIN'), findsOneWidget);
      expect(find.text('Archivos'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      final b = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Empezar'),
      );
      expect(b.onPressed, isNotNull);
    });

    testWidgets('"Generar código nuevo" es el mismo flujo con otro título', (
      tester,
    ) async {
      final env = await _env(tester, plan: _plan);
      await _open(tester, env, reason: RotationReason.newCode);
      expect(find.text('Generar código nuevo'), findsOneWidget);
      expect(find.textContaining('deje de servir del todo'), findsOneWidget);
    });

    testWidgets('archivos sin subir, sin espacio o sin sesión: no deja '
        'empezar y dice por qué', (tester) async {
      final env = await _env(
        tester,
        plan: const RotationPlan(
          items: 3,
          uploadBytes: 1,
          cloudOnlyBytes: 0,
          pendingUploads: 2,
          lostThumbnails: 1,
          quota: null,
          enoughDriveSpace: false,
          signedIn: false,
          oldAccountKept: 'vieja@example.com',
          noCopyItems: 4,
        ),
      );
      await _open(tester, env);
      expect(
        find.textContaining('4 archivo(s) no tienen ninguna copia'),
        findsOne,
      );
      expect(find.textContaining('2 archivo(s) sin subir'), findsOneWidget);
      expect(find.textContaining('no tiene espacio'), findsOneWidget);
      expect(find.textContaining('Inicia sesión con Google'), findsOneWidget);
      expect(find.textContaining('1 miniatura(s)'), findsOneWidget);
      expect(find.textContaining('vieja@example.com'), findsOneWidget);
      final b = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Empezar'),
      );
      expect(b.onPressed, isNull);
    });
  });

  testWidgets('PIN → código NUEVO sin salida → confirmar por posiciones → '
      'progreso; sin red queda en pausa y se puede cancelar', (tester) async {
    final env = await _env(tester, plan: _plan);
    await _open(tester, env);
    await tester.tap(find.text('Empezar'));
    await tester.pumpAndSettle();
    await _submitPin(tester, _pin);

    expect(find.text('Tu código NUEVO'), findsOneWidget);
    final shown = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('recovery-code-box')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data!)
        .join('-');
    final norm = RecoveryCode.normalize(shown)!;
    expect(
      (await tester.runAsync(env.auth.rotationRecord))!.phase,
      RotationPhase.prepared,
    );

    // Atrás no sale sin confirmar.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Tu código NUEVO'), findsOneWidget);

    await tester.tap(find.text('Ya lo anoté'));
    await tester.pumpAndSettle();
    final label = tester
        .widget<Text>(find.textContaining('Escribe los caracteres'))
        .data!;
    final positions = RegExp(
      r'(\d+)\.º',
    ).allMatches(label).map((m) => int.parse(m.group(1)!)).toList();
    await tester.enterText(
      find.byKey(const ValueKey('confirm-code-field')),
      [for (final p in positions) norm[p - 1]].join(),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
    await _settle(tester);

    final rec = (await tester.runAsync(env.auth.rotationRecord))!;
    expect(rec.phase, RotationPhase.confirmed);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rotation-phase'))).data,
      'Preparando el cambio de llave',
    );
    expect(find.byKey(const ValueKey('rotation-progress')), findsOneWidget);
    expect(find.text('En pausa: sin conexión.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rotation-advice'))).data,
      contains('sigue valiendo tu código anterior'),
    );
    expect(find.text('Continuar'), findsOneWidget);

    // Cancelar (nada re-cifrado): vuelve a la hoja previa.
    await tester.tap(find.text('Cancelar el cambio'));
    await _anim(tester);
    expect(find.text('¿Cancelar el cambio de llave?'), findsOneWidget);
    await tester.tap(find.text('Cancelar el cambio').last);
    await _settle(tester);
    expect(await tester.runAsync(env.auth.rotationRecord), isNull);
    expect(env.repo.clears, 1);
  });

  testWidgets('PIN incorrecto: no empieza', (tester) async {
    final env = await _env(tester, plan: _plan);
    await _open(tester, env);
    await tester.tap(find.text('Empezar'));
    await tester.pumpAndSettle();
    await _submitPin(tester, '654321');
    expect(find.text('PIN incorrecto'), findsOneWidget);
    expect(await tester.runAsync(env.auth.rotationRecord), isNull);
  });

  group('Estados', () {
    testWidgets('prepared: ofrece ver otro código nuevo', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _open(tester, env);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('rotation-phase'))).data,
        'Esperando que confirmes tu código nuevo',
      );
      expect(find.text('Ver otro código nuevo'), findsOneWidget);
      expect(find.text('Cancelar el cambio'), findsOneWidget);
      expect(find.byKey(const ValueKey('rotation-progress')), findsNothing);
    });

    testWidgets('re-cifrando: barra, avance y código NUEVO ya basta; no se '
        'puede cancelar', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(tester, env, RotationPhase.reencrypting);
      await _open(tester, env);
      env.service.status.value = const RotationStatus(
        phase: RotationPhase.reencrypting,
        running: true,
        itemsDone: 3,
        itemsTotal: 10,
      );
      await tester.pump();
      expect(find.text('Re-cifrando tus archivos'), findsOneWidget);
      expect(find.text('3 de 10'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('rotation-progress')),
      );
      expect(bar.value, closeTo(0.3, 1e-9));
      expect(find.textContaining('Ya basta con tu código NUEVO'), findsOne);
      expect(find.text('Pausar'), findsOneWidget);
      expect(find.text('Cancelar el cambio'), findsNothing);
    });

    testWidgets('tras borrar la copia anterior: solo vale el NUEVO', (
      tester,
    ) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(tester, env, RotationPhase.deletingOldCloud);
      await _open(tester, env);
      expect(find.text('Borrando la copia anterior de Drive'), findsOneWidget);
      expect(find.text('Tu código NUEVO ya es el único que vale.'), findsOne);
    });

    testWidgets('blockedCorrupt al re-cifrar: Omitir los dañados y '
        'Reintentar', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(
        tester,
        env,
        RotationPhase.blockedCorrupt,
        resume: RotationPhase.reencrypting,
        error: '2 archivos no se pueden abrir',
      );
      env.service.problems.value = const RotationProblems(
        damaged: [RotationProblemItem(id: 'a', name: 'roto.jpg')],
      );
      await _open(tester, env);
      expect(find.text('En pausa: hay un problema'), findsOneWidget);
      expect(find.text('2 archivos no se pueden abrir'), findsOneWidget);
      expect(find.text('Dañados (1)'), findsOneWidget);
      expect(find.text('roto.jpg'), findsOneWidget);
      expect(find.text('Continuar sin ellos'), findsNothing);
      expect(find.text('Omitir los dañados'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      await tester.tap(find.text('Omitir los dañados'));
      await _anim(tester);
      expect(find.text('¿Omitir los archivos dañados?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await _anim(tester);
    });

    testWidgets('sin ninguna copia: lista los nombres y "Continuar sin '
        'ellos" pide confirmación antes de quitarlos', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(
        tester,
        env,
        RotationPhase.blockedCorrupt,
        resume: RotationPhase.reencrypting,
        error: '10 archivo(s) sin ninguna copia y 1 archivo(s) dañado(s)',
      );
      env.service.problems.value = RotationProblems(
        missing: [
          for (var i = 0; i < 10; i++)
            RotationProblemItem(id: 'm$i', name: 'perdido_$i.jpg'),
        ],
        damaged: const [RotationProblemItem(id: 'd', name: 'roto.mp4')],
      );
      await _open(tester, env);
      expect(find.text('Sin ninguna copia (10)'), findsOneWidget);
      expect(find.text('perdido_0.jpg'), findsOneWidget);
      expect(find.text('perdido_7.jpg'), findsOneWidget);
      expect(find.text('perdido_8.jpg'), findsNothing);
      expect(find.text('y 2 más'), findsOneWidget);
      expect(find.text('Dañados (1)'), findsOneWidget);
      expect(find.text('Omitir los dañados'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);

      // Cancelar en la confirmación no quita nada.
      await tester.tap(find.text('Continuar sin ellos'));
      await _anim(tester);
      expect(find.text('¿Continuar sin estos archivos?'), findsOneWidget);
      expect(find.textContaining('NO se podrán recuperar'), findsOneWidget);
      expect(find.textContaining('10 archivo(s)'), findsWidgets);
      await tester.tap(find.text('Cancelar'));
      await _anim(tester);
      final svc = env.service as TestRotationService;
      expect(svc.drops, 0);

      await tester.tap(find.text('Continuar sin ellos'));
      await _anim(tester);
      await tester.tap(find.text('Quitar y continuar'));
      await _settle(tester);
      expect(svc.drops, 1);
    });

    testWidgets('tras reiniciar sin la llave: pide el PIN para ver la lista', (
      tester,
    ) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(
        tester,
        env,
        RotationPhase.blockedCorrupt,
        resume: RotationPhase.reencrypting,
        error: '1 archivo(s) sin ninguna copia',
      );
      await _open(tester, env);
      expect(
        find.byKey(const ValueKey('rotation-problems-loading')),
        findsOneWidget,
      );
      expect(find.textContaining('Desbloquea con tu PIN'), findsOneWidget);
      expect(find.text('Introducir PIN'), findsOneWidget);
      expect(find.text('Continuar sin ellos'), findsNothing);
    });

    testWidgets('blockedSignIn: Reintentar tras iniciar sesión', (
      tester,
    ) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(
        tester,
        env,
        RotationPhase.blockedSignIn,
        resume: RotationPhase.uploading,
        error: 'Inicia sesión con la cuenta de Google de siempre',
      );
      await _open(tester, env);
      expect(find.text('En pausa: inicia sesión con tu cuenta'), findsOne);
      expect(find.text('Reintentar tras iniciar sesión'), findsOneWidget);
    });

    testWidgets('blockedQuota: Reintentar', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(
        tester,
        env,
        RotationPhase.blockedQuota,
        resume: RotationPhase.uploading,
      );
      await _open(tester, env);
      expect(find.text('En pausa: tu Google Drive está lleno'), findsOne);
      expect(find.widgetWithText(FilledButton, 'Reintentar'), findsOneWidget);
    });

    testWidgets('blockedForeign: Descartar restos lo olvida', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(tester, env, RotationPhase.blockedForeign);
      await _open(tester, env);
      expect(
        find.text('Hay restos de un cambio de llave que no es de esta bóveda'),
        findsOneWidget,
      );
      await tester.tap(find.text('Descartar restos'));
      await _anim(tester);
      await tester.tap(find.text('Descartar restos').last);
      await _settle(tester);
      expect(await tester.runAsync(env.auth.rotationRecord), isNull);
      expect(find.text('Qué va a pasar'), findsOneWidget);
    });

    testWidgets('falta el PIN: Introducir PIN', (tester) async {
      final env = await _env(tester);
      await _prepare(tester, env);
      await _setPhase(tester, env, RotationPhase.uploading);
      await _open(tester, env);
      env.service.status.value = const RotationStatus(
        phase: RotationPhase.uploading,
        needsPin: true,
      );
      await tester.pump();
      expect(find.text('Introducir PIN'), findsOneWidget);
    });

    testWidgets('terminada: recuerda guardar SOLO el nuevo y ofrece la '
        'biometría', (tester) async {
      final env = await _env(tester);
      await _open(tester, env);
      env.service.status.value = const RotationStatus(
        finished: true,
        offerBiometric: true,
      );
      await tester.pump();
      expect(find.text('Rotación terminada'), findsOneWidget);
      expect(find.textContaining('Guarda SOLO el código nuevo'), findsOne);
      expect(find.text('Reactivar huella o Face ID'), findsOneWidget);
      expect(find.text('Listo'), findsOneWidget);
    });
  });

  group('Aviso (banner)', () {
    testWidgets('solo con una rotación en curso; el texto sigue la fase', (
      tester,
    ) async {
      final env = await _env(tester);
      var taps = 0;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: RotationBanner(
              record: env.auth.rotationStore.record,
              onTap: () => taps++,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('rotation-banner')), findsNothing);

      await _prepare(tester, env);
      await tester.pump();
      expect(find.textContaining('falta confirmar'), findsOneWidget);

      await _setPhase(tester, env, RotationPhase.reencrypting);
      expect(find.textContaining('Mantén Vault abierta'), findsOneWidget);

      await _setPhase(
        tester,
        env,
        RotationPhase.blockedQuota,
        resume: RotationPhase.uploading,
      );
      expect(find.textContaining('en pausa'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rotation-banner')));
      expect(taps, 1);
    });
  });

  test('etiquetas: cada fase tiene texto', () {
    for (final p in RotationPhase.values) {
      expect(rotationPhaseLabel(p), isNotEmpty);
    }
  });
}
