// ignore_for_file: depend_on_referenced_packages
// Capturas (goldens) de las pantallas principales. Se regeneran con:
//   flutter test --update-goldens test/ui/goldens
// y los PNG se copian a docs/screens/.
//
// Los textos usan Roboto del SDK de Flutter (FontLoader) y los íconos la
// fuente MaterialIcons, para que no salgan como bloques. Los goldens dependen
// de la plataforma de renderizado: se generaron en Windows.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/features/onboarding/onboarding_flow.dart';
import 'package:vault/features/onboarding/restore_flow.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/vault_media_viewer_screen.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';
import 'package:vault/features/vault/widgets/vault_sheets.dart';
import 'package:vault/shared/widgets/blur_sheet.dart';
import 'package:vault/shared/widgets/privacy_cover.dart';

import '../../support/fake_video_platform.dart';
import '../../support/fakes.dart';
import '../../support/scripted_restore.dart';
import '../../support/settings_support.dart';
import '../../support/ui_helpers.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Miniaturas sintéticas (degradados) ya decodificadas y en caché.
class _Thumbs {
  final Map<String, MemoryImage> byId = {};

  static const palette = <(Color, Color)>[
    (Color(0xFF7C3AED), Color(0xFFEC4899)),
    (Color(0xFF0EA5E9), Color(0xFF22D3EE)),
    (Color(0xFFF59E0B), Color(0xFFEF4444)),
    (Color(0xFF10B981), Color(0xFF3B82F6)),
    (Color(0xFF6366F1), Color(0xFF14B8A6)),
    (Color(0xFFF472B6), Color(0xFFFBBF24)),
  ];

  Future<void> build(WidgetTester tester, List<VaultItemModel> items) async {
    await tester.runAsync(() async {
      for (var i = 0; i < items.length; i++) {
        final (a, b) = palette[i % palette.length];
        byId[items[i].id] = MemoryImage(await makeThumbPng(a, b));
      }
    });
  }

  Future<void> precache(WidgetTester tester) async {
    final context = tester.element(find.byType(Scaffold).first);
    await tester.runAsync(() async {
      for (final image in byId.values) {
        await precacheImage(image, context);
      }
    });
  }

  Future<ImageProvider?> load(VaultItemModel item) async => byId[item.id];
}

List<VaultItemModel> _sampleItems() => [
  fakeItem('1', name: 'Atardecer.jpg', status: SyncStatus.enNube),
  fakeItem(
    '2',
    name: 'Cumpleaños.mp4',
    mime: 'video/mp4',
    status: SyncStatus.enCache,
    size: 48 * 1024 * 1024,
  ),
  fakeItem('3', name: 'Playa.jpg', status: SyncStatus.subiendo),
  fakeItem(
    '4',
    name: 'Contrato.pdf',
    mime: 'application/pdf',
    status: SyncStatus.pendiente,
    withThumb: false,
    size: 340 * 1024,
  ),
  fakeItem('5', name: 'Montaña.jpg', status: SyncStatus.sinConexion),
  fakeItem('6', name: 'Ciudad.jpg', status: SyncStatus.error),
  fakeItem('7', name: 'Familia.jpg', status: SyncStatus.enNube),
  fakeItem('8', name: 'Receta.jpg', status: SyncStatus.enNube),
];

Future<void> _pumpHome(
  WidgetTester tester, {
  required FakeVaultRepository repo,
  _Thumbs? thumbs,
  String? folderId,
  String name = 'Mi Bóveda',
  int columns = 3,
  Widget Function(Widget home)? wrap,
}) async {
  usePhoneSize(tester);
  final home = HomeVaultScreen(
    currentFolderId: folderId,
    currentFolderName: name,
    initialColumns: columns,
    services: fakeServices(repo, thumbnails: thumbs?.load),
  );
  await tester.pumpWidget(testApp(wrap?.call(home) ?? home));
  await tester.pump();
  await thumbs?.precache(tester);
  await tester.pump(const Duration(seconds: 1));
}

Future<AuthController> _controller({bool createVault = false}) async {
  final c = AuthController(
    storage: InMemorySecureStore(),
    biometricStore: FakeBiometricKeyStore()
      ..available = BiometricAvailability.unavailable,
    kdfParams: fastKdf,
    session: VaultSession.create(),
    // Determinista: el código de recuperación sale igual en cada captura.
    random: Random(7),
  );
  if (createVault) {
    await c.createVault('1234');
    c.lock();
  }
  return c;
}

Future<void> _digits(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.bySemanticsLabel('Dígito $d'));
    await tester.pump();
  }
}

/// Captura la app.
Future<void> _shot(String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile(name));

/// Como `testWidgets`, pero con sombras reales (las pruebas las desactivan
/// por defecto y deben quedar así al terminar).
void goldenTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDisableShadows = false;
    try {
      await body(tester);
    } finally {
      debugDisableShadows = true;
    }
  });
}

void main() {
  setUpAll(() async {
    final ok = await loadGoldenFonts();
    if (!ok) {
      // ignore: avoid_print
      print(
        'AVISO: no se encontraron las fuentes del SDK; el texto saldrá como cajas.',
      );
    }
  });

  // Las pruebas desactivan las sombras por defecto; las capturas las muestran.
  group('PIN', () {
    goldenTest('pin', (tester) async {
      usePhoneSize(tester);
      final c = await _controller(createVault: true);
      await tester.pumpWidget(
        testApp(PinScreen(authController: c, onAuthenticated: () {})),
      );
      await tester.pump();
      await _digits(tester, '24');
      await tester.pump(const Duration(milliseconds: 400));
      await _shot('pin.png');
    });

    goldenTest('pin_error', (tester) async {
      usePhoneSize(tester);
      final c = await _controller(createVault: true);
      await tester.pumpWidget(
        testApp(PinScreen(authController: c, onAuthenticated: () {})),
      );
      await tester.pump();
      await _digits(tester, '9999');
      await tester.tap(find.text('Continuar'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 380));
      await _shot('pin_error.png');
      await tester.pump(const Duration(seconds: 2));
    });

    goldenTest('crear_boveda', (tester) async {
      usePhoneSize(tester);
      final c = await _controller();
      await tester.pumpWidget(
        testApp(PinScreen(authController: c, onAuthenticated: () {})),
      );
      await tester.pump();
      await _digits(tester, '135');
      await tester.pump(const Duration(milliseconds: 400));
      await _shot('crear_boveda.png');
    });
  });

  group('F9: restaurar', () {
    Future<ScriptedRestoreService> pumpRestore(
      WidgetTester tester, {
      RestoreStep step = RestoreStep.start,
    }) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..gate = Completer<void>()
        ..script = const [
          RestoreProgress(RestoreStage.thumbnails, done: 42, total: 120),
        ];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SafeArea(
              child: RestoreFlow(
                service: svc,
                initialStep: step,
                onRestored: (_) {},
                onCreateNew: () {},
                onBack: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      return svc;
    }

    goldenTest('restaurar_inicio', (tester) async {
      await pumpRestore(tester);
      await _shot('restaurar_inicio.png');
    });

    goldenTest('restaurar_codigo', (tester) async {
      await pumpRestore(tester, step: RestoreStep.code);
      await tester.enterText(
        find.byKey(const ValueKey('restore-code-field')),
        'abcdefghjkmnpqrstuvwxyz2',
      );
      await tester.pump();
      await _shot('restaurar_codigo.png');
    });

    goldenTest('restaurar_progreso', (tester) async {
      await pumpRestore(tester, step: RestoreStep.code);
      await tester.enterText(
        find.byKey(const ValueKey('restore-code-field')),
        'ABCDEFGHJKMNPQRSTUVWXYZ2',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      for (final pin in ['1357', '1357']) {
        await _digits(tester, pin);
        await tester.tap(find.text('Continuar'));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      await _shot('restaurar_progreso.png');
    });
  });

  group('F8: onboarding y ajustes', () {
    const code = 'ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2';

    Future<void> pumpOnboarding(
      WidgetTester tester, {
      bool resume = false,
    }) async {
      usePhoneSize(tester);
      final c = await _controller();
      await tester.pumpWidget(
        testApp(
          OnboardingFlow(
            auth: c,
            resume: resume,
            recoveryCode: resume ? code : null,
            random: Random(3), // posiciones reproducibles
            onFinished: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    goldenTest('onboarding_bienvenida', (tester) async {
      await pumpOnboarding(tester);
      await _shot('onboarding_bienvenida.png');
    });

    goldenTest('onboarding_codigo', (tester) async {
      await pumpOnboarding(tester, resume: true);
      await _shot('onboarding_codigo.png');
    });

    goldenTest('onboarding_confirmacion', (tester) async {
      await pumpOnboarding(tester, resume: true);
      await tester.tap(find.text('Ya lo anoté'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.enterText(
        find.byKey(const ValueKey('confirm-code-field')),
        'AB',
      );
      await tester.pump();
      await _shot('onboarding_confirmacion.png');
    });

    goldenTest('onboarding_confirmacion_error', (tester) async {
      await pumpOnboarding(tester, resume: true);
      await tester.tap(find.text('Ya lo anoté'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.enterText(
        find.byKey(const ValueKey('confirm-code-field')),
        'ZZZZ',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _shot('onboarding_confirmacion_error.png');
    });

    Future<SettingsTestEnv> pumpSettings(
      WidgetTester tester, {
      required Size size,
    }) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = size * 2;
      addTearDown(tester.view.reset);
      final e = SettingsTestEnv();
      await tester.runAsync(e.init);
      addTearDown(e.dispose);
      await tester.pumpWidget(e.screen());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(seconds: 1));
      return e;
    }

    goldenTest('ajustes', (tester) async {
      await pumpSettings(tester, size: const Size(390, 844));
      await _shot('ajustes.png');
    });

    goldenTest('ajustes_completo', (tester) async {
      await pumpSettings(tester, size: const Size(390, 2300));
      await _shot('ajustes_completo.png');
    });
  });

  group('F7: seguridad', () {
    goldenTest('home_bloquear_ahora', (tester) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(FakeVaultRepository()),
            onLock: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _shot('home_bloquear_ahora.png');
    });

    goldenTest('privacy_cover', (tester) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          const PrivacyCover(
            state: AppLifecycleState.inactive,
            child: Text('contenido secreto'),
          ),
        ),
      );
      await tester.pump();
      await _shot('privacy_cover.png');
    });
  });

  group('Bóveda', () {
    goldenTest('home_vacio', (tester) async {
      await _pumpHome(tester, repo: FakeVaultRepository());
      await _shot('home_vacio.png');
    });

    goldenTest('home_cuadricula', (tester) async {
      final items = _sampleItems();
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        repo: FakeVaultRepository(
          folders: [fakeFolder('d1', 'Viajes'), fakeFolder('d2', 'Documentos')],
          items: items,
        ),
      );
      await _shot('home_cuadricula.png');
    });

    goldenTest('home_cargando_skeleton', (tester) async {
      final items = _sampleItems();
      final never = Completer<ImageProvider?>();
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(
              FakeVaultRepository(items: items),
              thumbnails: (_) => never.future,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await _shot('home_skeleton.png');
    });

    goldenTest('home_lista_swipe', (tester) async {
      final items = _sampleItems();
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        columns: 1,
        repo: FakeVaultRepository(
          folders: [fakeFolder('d1', 'Viajes')],
          items: items,
        ),
      );
      await tester.drag(find.text('Playa.jpg'), const Offset(-400, 0));
      await tester.pump(const Duration(seconds: 1));
      await _shot('home_lista_swipe.png');
    });

    goldenTest('home_subcarpeta_breadcrumbs', (tester) async {
      final items = [
        fakeItem('1', name: 'Atardecer.jpg', folderId: 'c'),
        fakeItem(
          '2',
          name: 'Playa.jpg',
          folderId: 'c',
          status: SyncStatus.enCache,
        ),
      ];
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        folderId: 'c',
        name: 'Verano',
        repo: FakeVaultRepository(
          folders: [
            fakeFolder('a', 'Viajes'),
            fakeFolder('b', '2025', parentId: 'a'),
            fakeFolder('c', 'Verano', parentId: 'b'),
          ],
          items: items,
        ),
      );
      await _shot('home_breadcrumbs.png');
    });

    goldenTest('seleccion', (tester) async {
      final items = _sampleItems();
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        repo: FakeVaultRepository(
          folders: [fakeFolder('d1', 'Viajes'), fakeFolder('d2', 'Documentos')],
          items: items,
        ),
      );
      await tester.longPress(find.text('Playa.jpg'));
      await _settle(tester);
      await tester.tap(find.text('Ciudad.jpg'));
      await tester.tap(find.text('Viajes'));
      await _settle(tester);
      await _shot('seleccion.png');
    });

    goldenTest('busqueda', (tester) async {
      final items = _sampleItems();
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        repo: FakeVaultRepository(items: items),
      );
      await tester.tap(find.byTooltip('Buscar'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'jpg');
      await _settle(tester);
      await _shot('busqueda.png');
    });

    goldenTest('fab_expandido', (tester) async {
      final items = _sampleItems();
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        repo: FakeVaultRepository(
          folders: [fakeFolder('d1', 'Viajes')],
          items: items,
        ),
      );
      await tester.tap(find.bySemanticsLabel('Añadir'));
      await _settle(tester);
      await _shot('fab_expandido.png');
    });

    goldenTest('bottom_sheet', (tester) async {
      final items = _sampleItems();
      final thumbs = _Thumbs();
      await thumbs.build(tester, items);
      await _pumpHome(
        tester,
        thumbs: thumbs,
        repo: FakeVaultRepository(items: items),
      );
      await tester.tap(find.bySemanticsLabel('Añadir'));
      await _settle(tester);
      await tester.tap(find.text('Importar archivo'));
      await _settle(tester);
      expect(find.text('Importar al Vault'), findsOneWidget);
      await _shot('bottom_sheet.png');
      expect(find.byType(BlurSheet), findsOneWidget);
      expect(find.byType(ImportConfirmContent), findsOneWidget);
    });

    goldenTest('visor', (tester) async {
      usePhoneSize(tester);
      final item = fakeItem('1', name: 'Atardecer.jpg');
      late Uint8List png;
      await tester.runAsync(() async {
        png = await makeThumbPng(
          const Color(0xFF7C3AED),
          const Color(0xFFFBBF24),
          size: 800,
        );
      });
      await tester.pumpWidget(
        testApp(
          VaultMediaViewerScreen(
            items: [item, fakeItem('2'), fakeItem('3')],
            initialIndex: 0,
            mediaOpener: FakeMediaOpener(images: {'1': png}),
            session: VaultSession.create(),
          ),
        ),
      );
      await tester.pump();
      final context = tester.element(find.byType(Scaffold));
      await tester.runAsync(() => precacheImage(MemoryImage(png), context));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Image), findsOneWidget);
      await _shot('visor.png');
    });

    goldenTest('confirmar_eliminar', (tester) async {
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showConfirmDeleteSheet(
                    context,
                    count: 1,
                    includesFolders: false,
                  ),
                  child: const Text('eliminar'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('eliminar'));
      await _settle(tester);
      expect(
        find.textContaining('También se eliminará de la nube'),
        findsOneWidget,
      );
      await _shot('confirmar_eliminar.png');
    });

    Future<void> pumpVideoViewer(
      WidgetTester tester, {
      required VideoSource Function(VaultItemModel) factory,
    }) async {
      final video = fakeItem('7', name: 'Cumpleaños.mp4', mime: 'video/mp4');
      final thumbs = _Thumbs();
      await thumbs.build(tester, [video]);
      await tester.pumpWidget(
        testApp(
          VaultMediaViewerScreen(
            items: [video],
            initialIndex: 0,
            mediaOpener: FakeMediaOpener()..videoFactory = factory,
            thumbnailLoader: thumbs.load,
            session: VaultSession.create(),
          ),
        ),
      );
      await tester.pump();
      await thumbs.precache(tester);
      await _settle(tester);
    }

    goldenTest('visor_video_inicio', (tester) async {
      await pumpVideoViewer(tester, factory: (_) => _GoldenSource(null));
      expect(find.byKey(const ValueKey('video-play')), findsOneWidget);
      await _shot('visor_video_inicio.png');
    });

    goldenTest('visor_video_descarga', (tester) async {
      final gate = Completer<void>();
      await pumpVideoViewer(
        tester,
        factory: (_) => _GoldenSource((p) async {
          p?.call(const MediaProgress(MediaPhase.downloading, 0.42));
          await gate.future;
        }),
      );
      await tester.tap(find.byKey(const ValueKey('video-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Descargando de Drive'), findsOneWidget);
      await _shot('visor_video_descarga.png');
      gate.complete();
      await tester.pump();
    });

    goldenTest('visor_video_controles', (tester) async {
      VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
      await pumpVideoViewer(
        tester,
        factory: (_) => _GoldenSource((_) async {}),
      );
      await tester.tap(find.byKey(const ValueKey('video-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
      await _shot('visor_video_controles.png');
    });
  });
}

/// Origen de video para las capturas: [onOpen] simula progreso/espera y, si
/// no es nulo, devuelve un controlador inicializado con la plataforma falsa.
class _GoldenSource implements VideoSource {
  _GoldenSource(this.onOpen);
  final Future<void> Function(MediaProgressCallback? p)? onOpen;
  VideoPlayerController? _c;

  @override
  Future<VideoPlayerController> open({
    MediaProgressCallback? onProgress,
  }) async {
    await onOpen?.call(onProgress);
    final c = VideoPlayerController.file(File('clip.mp4'));
    await c.initialize();
    return _c = c;
  }

  @override
  Future<void> release() async => _c?.dispose();

  @override
  Object? get playbackFailure => null;
}
