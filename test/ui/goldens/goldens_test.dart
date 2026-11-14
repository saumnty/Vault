// Capturas (goldens) de las pantallas principales. Se regeneran con:
//   flutter test --update-goldens test/ui/goldens
// y los PNG se copian a docs/screens/.
//
// Los textos usan Roboto del SDK de Flutter (FontLoader) y los íconos la
// fuente MaterialIcons, para que no salgan como bloques. Los goldens dependen
// de la plataforma de renderizado: se generaron en Windows.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/vault_media_viewer_screen.dart';
import 'package:vault/features/vault/models/browser_entry.dart';
import 'package:vault/features/vault/widgets/vault_sheets.dart';
import 'package:vault/shared/widgets/blur_sheet.dart';

import '../../support/fakes.dart';
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

    goldenTest('recuperacion', (tester) async {
      usePhoneSize(tester);
      final c = await _controller();
      await tester.pumpWidget(
        testApp(PinScreen(authController: c, onAuthenticated: () {})),
      );
      await tester.pump();
      await _digits(tester, '1357');
      await tester.tap(find.text('Continuar'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Código de recuperación'), findsOneWidget);
      await _shot('recuperacion.png');
      await tester.tap(find.text('Ya lo guardé'));
      await tester.pump(const Duration(seconds: 2));
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
      final file = File(
        'no-se-lee.png',
      ); // el proveedor devuelve la imagen en memoria
      late MemoryImage image;
      await tester.runAsync(() async {
        image = MemoryImage(
          await makeThumbPng(
            const Color(0xFF7C3AED),
            const Color(0xFFFBBF24),
            size: 800,
          ),
        );
      });
      await tester.pumpWidget(
        testApp(
          VaultMediaViewerScreen(
            item: item,
            heroTag: FileEntry.heroTagFor(item.id),
            mediaLoader: (_) async => file,
            imageProviderFor: (_) => image,
          ),
        ),
      );
      await tester.pump();
      final context = tester.element(find.byType(Scaffold));
      await tester.runAsync(() => precacheImage(image, context));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Image), findsOneWidget);
      await _shot('visor.png');
    });
  });
}
