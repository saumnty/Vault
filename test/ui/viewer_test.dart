// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/core/streaming/vault_stream_server.dart';
import 'package:vault/core/theme/app_spacing.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/vault/vault_media_viewer_screen.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';
import 'package:vault/features/vault/viewer/video_page.dart';

import '../support/f6_env.dart';
import '../support/fake_video_platform.dart';
import '../support/ui_helpers.dart';

/// Origen de video controlable desde la prueba.
class _FakeSource implements VideoSource {
  _FakeSource(this.onOpen);
  final Future<VideoPlayerController> Function(MediaProgressCallback? p) onOpen;
  int released = 0;
  VideoPlayerController? controller;
  @override
  Object? playbackFailure;

  @override
  Future<VideoPlayerController> open({
    MediaProgressCallback? onProgress,
  }) async {
    controller = await onOpen(onProgress);
    return controller!;
  }

  @override
  Future<void> release() async {
    released++;
    await controller?.dispose();
    controller = null;
  }
}

Future<VideoPlayerController> _readyController() async {
  final c = VideoPlayerController.file(File('clip.mp4'));
  await c.initialize();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List png;
  late FakeVideoPlayerPlatform platform;

  setUp(() {
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  Future<void> loadPng(WidgetTester tester) async {
    await tester.runAsync(() async {
      png = await makeThumbPng(
        const Color(0xFF7C3AED),
        const Color(0xFFFBBF24),
        size: 400,
      );
    });
  }

  final items = [
    fakeItem('1', name: 'uno.jpg'),
    fakeItem('2', name: 'dos.jpg'),
    fakeItem('3', name: 'tres.mp4', mime: 'video/mp4'),
  ];

  Future<VaultSession> pumpViewer(
    WidgetTester tester,
    MediaOpener opener, {
    int initial = 0,
    List<VaultItemModel>? list,
  }) async {
    usePhoneSize(tester);
    final session = VaultSession.create();
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VaultMediaViewerScreen(
                      items: list ?? items,
                      initialIndex: initial,
                      mediaOpener: opener,
                      session: session,
                    ),
                  ),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return session;
  }

  double scaleOf(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byKey(const ValueKey('photo-zoom')))
      .transformationController!
      .value
      .getMaxScaleOnAxis();

  testWidgets(
    'foto: carga en memoria y muestra imagen con semántica en español',
    (tester) async {
      await loadPng(tester);
      final opener = FakeMediaOpener(images: {'1': png, '2': png});
      await pumpViewer(tester, opener);

      expect(opener.loaded, ['1']); // solo la visible, sin precargar vecinas
      expect(find.byType(Image), findsOneWidget);
      expect(find.bySemanticsLabel('Imagen uno.jpg'), findsOneWidget);
      expect(find.text('uno.jpg'), findsOneWidget);
      expect(find.textContaining('1 / 3'), findsOneWidget);
    },
  );

  testWidgets('foto: doble toque amplía y otro doble toque restaura', (
    tester,
  ) async {
    await loadPng(tester);
    await pumpViewer(tester, FakeMediaOpener(images: {'1': png}));
    expect(scaleOf(tester), 1);

    final center = tester.getCenter(find.byKey(const ValueKey('photo-zoom')));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(scaleOf(tester), closeTo(2.5, 0.05));

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(scaleOf(tester), closeTo(1, 0.02));
  });

  testWidgets('foto: pellizco amplía y con zoom no se desliza entre páginas', (
    tester,
  ) async {
    await loadPng(tester);
    final opener = FakeMediaOpener(images: {'1': png, '2': png});
    await pumpViewer(tester, opener);
    final center = tester.getCenter(find.byKey(const ValueKey('photo-zoom')));

    final a = await tester.startGesture(center - const Offset(20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await a.moveBy(const Offset(-60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(scaleOf(tester), greaterThan(1.5));

    final pages = tester.widget<PageView>(
      find.byKey(const ValueKey('viewer-pages')),
    );
    expect(pages.physics, isA<NeverScrollableScrollPhysics>());
    expect(opener.loaded, ['1']);
  });

  testWidgets(
    'foto: deslizar navega a la siguiente (PageView) y actualiza la posición',
    (tester) async {
      await loadPng(tester);
      final opener = FakeMediaOpener(images: {'1': png, '2': png});
      await pumpViewer(tester, opener);

      await tester.fling(
        find.byKey(const ValueKey('viewer-pages')),
        const Offset(-400, 0),
        1500,
      );
      await tester.pumpAndSettle();

      expect(opener.loaded, ['1', '2']);
      expect(find.text('dos.jpg'), findsOneWidget);
      expect(find.textContaining('2 / 3'), findsOneWidget);
    },
  );

  testWidgets('abre en el índice indicado', (tester) async {
    await loadPng(tester);
    final opener = FakeMediaOpener(images: {'2': png});
    await pumpViewer(tester, opener, initial: 1);
    expect(opener.loaded, ['2']);
    expect(find.text('dos.jpg'), findsOneWidget);
  });

  testWidgets('error de descarga: mensaje claro y Reintentar funciona', (
    tester,
  ) async {
    await loadPng(tester);
    final opener = FakeMediaOpener(images: {'1': png})
      ..failuresBeforeSuccess = 1; // sin red la primera vez
    await pumpViewer(tester, opener);

    expect(find.byKey(const ValueKey('photo-error')), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(opener.loaded, ['1', '1']);
    expect(find.byKey(const ValueKey('photo-error')), findsNothing);
    expect(find.byKey(const ValueKey('photo-zoom')), findsOneWidget);
  });

  testWidgets('error sin reintento (copia dañada) no ofrece Reintentar', (
    tester,
  ) async {
    final opener = FakeMediaOpener()
      ..imageError = const CloudNotFoundException();
    await pumpViewer(tester, opener);
    expect(find.byKey(const ValueKey('photo-error')), findsOneWidget);
    expect(find.text('Reintentar'), findsNothing);
  });

  testWidgets('imagen corrupta: no se cae, muestra mensaje', (tester) async {
    final opener = FakeMediaOpener(
      images: {
        '1': Uint8List.fromList([1, 2, 3, 4]),
      },
    );
    await pumpViewer(tester, opener);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('photo-decode-error')), findsOneWidget);
  });

  testWidgets('un toque oculta la barra y otro la muestra', (tester) async {
    await loadPng(tester);
    await pumpViewer(tester, FakeMediaOpener(images: {'1': png}));

    double opacityOfClose() {
      final o = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byTooltip('Cerrar'),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      return o.opacity;
    }

    expect(opacityOfClose(), 1);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('photo-zoom'))),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(opacityOfClose(), 0);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('photo-zoom'))),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(opacityOfClose(), 1);
  });

  testWidgets('botón cerrar vuelve; áreas táctiles >= 44', (tester) async {
    await loadPng(tester);
    await pumpViewer(tester, FakeMediaOpener(images: {'1': png}));
    for (final tip in ['Cerrar', 'Información del archivo']) {
      final size = tester.getSize(find.byTooltip(tip));
      expect(size.width, greaterThanOrEqualTo(AppSizes.minTouch), reason: tip);
      expect(size.height, greaterThanOrEqualTo(AppSizes.minTouch), reason: tip);
    }
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.byType(VaultMediaViewerScreen), findsNothing);
    expect(find.text('abrir'), findsOneWidget);
  });

  testWidgets('hoja de información muestra metadatos básicos', (tester) async {
    await loadPng(tester);
    await pumpViewer(tester, FakeMediaOpener(images: {'1': png}));
    await tester.tap(find.byTooltip('Información del archivo'));
    await tester.pumpAndSettle();
    expect(find.text('Tipo'), findsOneWidget);
    expect(find.text('Imagen'), findsOneWidget);
    expect(find.text('Tamaño'), findsOneWidget);
    expect(find.text('2,00 MB'), findsOneWidget);
    expect(find.text('2026-03-14'), findsOneWidget);
    expect(find.text('En la nube'), findsWidgets);
  });

  testWidgets('al bloquear la bóveda el visor se cierra', (tester) async {
    await loadPng(tester);
    final session = await pumpViewer(
      tester,
      FakeMediaOpener(images: {'1': png}),
    );
    expect(find.byType(VaultMediaViewerScreen), findsOneWidget);
    session.clear();
    await tester.pumpAndSettle();
    expect(find.byType(VaultMediaViewerScreen), findsNothing);
  });

  testWidgets('tipo sin vista previa muestra mensaje', (tester) async {
    final doc = fakeItem('9', name: 'notas.docx', mime: 'application/msword');
    await pumpViewer(tester, FakeMediaOpener(), list: [doc]);
    expect(find.textContaining('Vista previa no disponible'), findsOneWidget);
  });

  group('video', () {
    final videoItem = fakeItem('3', name: 'tres.mp4', mime: 'video/mp4');

    testWidgets('no abre nada hasta tocar Reproducir', (tester) async {
      var created = 0;
      final opener = FakeMediaOpener()
        ..videoFactory = (i) {
          created++;
          return _FakeSource((_) async => _readyController());
        };
      await pumpViewer(tester, opener, list: [videoItem]);
      expect(created, 0);
      expect(
        find.bySemanticsLabel('Reproducir video tres.mp4'),
        findsOneWidget,
      );
    });

    testWidgets(
      'muestra progreso de descarga y descifrado y luego los controles',
      (tester) async {
        final gate = Completer<void>();
        late _FakeSource source;
        final opener = FakeMediaOpener()
          ..videoFactory = (i) => source = _FakeSource((p) async {
            p?.call(const MediaProgress(MediaPhase.downloading, 0.4));
            await gate.future;
            p?.call(const MediaProgress(MediaPhase.decrypting, 0.5));
            return _readyController();
          });
        await pumpViewer(tester, opener, list: [videoItem]);

        await tester.tap(find.byKey(const ValueKey('video-play')));
        await tester.pump();
        expect(find.byKey(const ValueKey('video-opening')), findsOneWidget);
        expect(find.textContaining('Descargando de Drive'), findsOneWidget);
        expect(find.textContaining('40 %'), findsOneWidget);

        gate.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('video-opening')), findsNothing);
        expect(find.byType(VideoPlayer), findsOneWidget);
        expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
        // Regresión: el Slider ocupaba toda la pantalla si el Row no tenía alto.
        expect(
          tester.getSize(find.byType(VideoControls)).height,
          lessThan(120),
        );
        expect(find.byTooltip('Pantalla completa'), findsOneWidget);
        expect(find.text('0:25'), findsOneWidget); // duración
        expect(platform.calls, contains('play'));

        // Pausar y reproducir con los controles propios (>= 44).
        final pause = find.byTooltip('Pausar');
        expect(pause, findsOneWidget);
        expect(
          tester.getSize(pause).shortestSide,
          greaterThanOrEqualTo(AppSizes.minTouch),
        );

        // Cerrar el visor libera el origen (que borra el temporal).
        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pumpAndSettle();
        expect(source.released, 1);
      },
    );

    testWidgets('error al abrir: mensaje, Reintentar crea un origen nuevo', (
      tester,
    ) async {
      final sources = <_FakeSource>[];
      var fail = true;
      final opener = FakeMediaOpener()
        ..videoFactory = (i) {
          final s = _FakeSource((_) async {
            if (fail) throw const CloudNoNetworkException();
            return _readyController();
          });
          sources.add(s);
          return s;
        };
      await pumpViewer(tester, opener, list: [videoItem]);

      await tester.tap(find.byKey(const ValueKey('video-play')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-error')), findsOneWidget);
      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(sources.single.released, 1); // se libera lo parcial

      fail = false;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(sources.length, 2);
      expect(find.byType(VideoPlayer), findsOneWidget);
    });

    testWidgets('salir de la página de video (deslizar) libera el origen', (
      tester,
    ) async {
      await loadPng(tester);
      late _FakeSource source;
      final opener = FakeMediaOpener(images: {'1': png})
        ..videoFactory = (i) =>
            source = _FakeSource((_) async => _readyController());
      await pumpViewer(
        tester,
        opener,
        list: [
          videoItem,
          fakeItem('1', name: 'uno.jpg'),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('video-play')));
      await tester.pumpAndSettle();
      expect(find.byType(VideoPlayer), findsOneWidget);

      await tester.fling(
        find.byKey(const ValueKey('viewer-pages')),
        const Offset(-400, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(source.released, 1);
    });

    testWidgets('al bloquear con un video abierto se libera todo', (
      tester,
    ) async {
      late _FakeSource source;
      final opener = FakeMediaOpener()
        ..videoFactory = (i) =>
            source = _FakeSource((_) async => _readyController());
      final session = await pumpViewer(tester, opener, list: [videoItem]);
      await tester.tap(find.byKey(const ValueKey('video-play')));
      await tester.pumpAndSettle();

      session.clear();
      await tester.pumpAndSettle();
      expect(find.byType(VaultMediaViewerScreen), findsNothing);
      expect(source.released, 1);
    });
    testWidgets(
      'integridad durante la reproducción: mensaje de archivo dañado, sin '
      'Reintentar, y se libera el origen',
      (tester) async {
        late _FakeSource source;
        final opener = FakeMediaOpener()
          ..videoFactory = (i) =>
              source = _FakeSource((_) async => _readyController());
        await pumpViewer(tester, opener, list: [videoItem]);
        await tester.tap(find.byKey(const ValueKey('video-play')));
        await tester.pumpAndSettle();
        expect(find.byType(VideoPlayer), findsOneWidget);

        // El servidor cortó la respuesta: el origen conoce la causa y el
        // reproductor nativo emite un error.
        source.playbackFailure = const VaultAuthException('bloque 3');
        platform.emitError(platform.playerIds.last, 'Source error');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('video-error')), findsOneWidget);
        expect(find.textContaining('dañado'), findsOneWidget);
        expect(find.text('Reintentar'), findsNothing);
        expect(source.released, 1);
      },
    );

    testWidgets('error genérico del reproductor: mensaje y Reintentar', (
      tester,
    ) async {
      final opener = FakeMediaOpener()
        ..videoFactory = (i) => _FakeSource((_) async => _readyController());
      await pumpViewer(tester, opener, list: [videoItem]);
      await tester.tap(find.byKey(const ValueKey('video-play')));
      await tester.pumpAndSettle();
      platform.emitError(platform.playerIds.last, 'codec');
      await tester.pumpAndSettle();
      expect(find.textContaining('no pudo leer'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets(
      'app a segundo plano: libera el origen (cierra el servidor) y al volver '
      'a reproducir reanuda en la misma posición',
      (tester) async {
        final sources = <_FakeSource>[];
        final opener = FakeMediaOpener()
          ..videoFactory = (i) {
            final s = _FakeSource((_) async => _readyController());
            sources.add(s);
            return s;
          };
        await pumpViewer(tester, opener, list: [videoItem]);
        await tester.tap(find.byKey(const ValueKey('video-play')));
        await tester.pumpAndSettle();
        await sources.single.controller!.seekTo(const Duration(seconds: 12));
        await tester.pump(const Duration(seconds: 1));

        for (final st in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(st);
        }
        await tester.pump();
        expect(sources.single.released, 1);

        // (En segundo plano no se dibujan frames: se comprueba al volver.)
        for (final st in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(st);
        }
        await tester.pumpAndSettle();
        expect(find.byType(VideoPlayer), findsNothing);
        expect(find.byKey(const ValueKey('video-play')), findsOneWidget);
        platform.calls.clear();
        await tester.tap(find.byKey(const ValueKey('video-play')));
        await tester.pumpAndSettle();
        expect(sources.length, 2);
        expect(find.byType(VideoPlayer), findsOneWidget);
        expect(platform.calls, containsAllInOrder(['seek', 'play']));
        expect(
          await sources.last.controller!.position,
          const Duration(seconds: 12),
        );
      },
    );

    testWidgets(
      'visor REAL: si el streaming no inicializa cae a completo-primero y '
      'reproduce; al cerrar no queda nada en claro',
      (tester) async {
        final env = F6Env();
        late VaultItemModel item;
        await tester.runAsync(() async {
          await env.setUp();
          item = await env.addCloudItem(
            'v',
            plain: Uint8List.fromList(List.generate(300000, (i) => i % 251)),
            name: 'clip.mp4',
            mime: 'video/mp4',
          );
        });
        final temp = PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir);
        // Plataforma que no deja usar la URL local (cleartext bloqueado).
        platform.onCreate = (ds) async {
          if (ds.sourceType == DataSourceType.network) {
            throw PlatformException(code: 'VideoError', message: 'cleartext');
          }
        };
        final opener = VaultMediaOpener(
          fetcher: env.fetcher,
          filesKey: () => env.session.filesKey,
          temp: temp,
          session: env.session,
        );
        await pumpViewer(tester, opener, list: [item]);
        await tester.tap(find.byKey(const ValueKey('video-play')));
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
          if (find.byType(VideoPlayer).evaluate().isNotEmpty) break;
        }
        expect(find.byType(VideoPlayer), findsOneWidget);
        expect(platform.openedUris.first, startsWith('http://127.0.0.1:'));
        expect(platform.openedUris.last, contains(AppPaths.tmpPlainDirName));
        expect(VaultStreamServer.liveCount, 0);

        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
        }
        await tester.runAsync(() async {
          final dir = AppPaths.tmpPlainDir;
          expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
          await env.tearDown();
        });
      },
    );
  });
}
