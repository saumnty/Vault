// ignore_for_file: depend_on_referenced_packages
// Fase 10 (v2): gestos del video (doble toque ±10 s con racha, zoom 1x-4x).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/vault/vault_media_viewer_screen.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';
import 'package:vault/features/vault/viewer/video_gestures.dart';

import '../support/fake_video_platform.dart';
import '../support/ui_helpers.dart';

class _FakeSource implements VideoSource {
  VideoPlayerController? controller;
  @override
  Object? playbackFailure;

  @override
  Future<VideoPlayerController> open({
    MediaProgressCallback? onProgress,
  }) async {
    final c = VideoPlayerController.file(File('clip.mp4'));
    await c.initialize();
    return controller = c;
  }

  @override
  Future<void> release() async {
    await controller?.dispose();
    controller = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVideoPlayerPlatform platform;
  var haptics = 0;

  setUp(() {
    platform = FakeVideoPlayerPlatform()..duration = const Duration(minutes: 2);
    VideoPlayerPlatform.instance = platform;
    haptics = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics++;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('skipTarget', () {
    const d = Duration(seconds: 25);
    test('suma y resta saltos de 10 s', () {
      expect(skipTarget(const Duration(seconds: 5), 1, d).inSeconds, 15);
      expect(skipTarget(const Duration(seconds: 5), 2, d).inSeconds, 25);
      expect(skipTarget(const Duration(seconds: 15), -1, d).inSeconds, 5);
    });
    test('respeta inicio y fin', () {
      expect(skipTarget(const Duration(seconds: 5), -1, d), Duration.zero);
      expect(skipTarget(const Duration(seconds: 20), 1, d), d);
      expect(skipTarget(const Duration(seconds: 20), 9, d), d);
      expect(skipTarget(Duration.zero, -3, d), Duration.zero);
    });
  });

  Future<void> pumpViewer(WidgetTester t, {List<VaultItemModel>? list}) async {
    usePhoneSize(t);
    final session = VaultSession.create();
    final opener = FakeMediaOpener()..videoFactory = (i) => _FakeSource();
    await t.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VaultMediaViewerScreen(
                      items:
                          list ??
                          [fakeItem('3', name: 'tres.mp4', mime: 'video/mp4')],
                      initialIndex: 0,
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
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('video-play')));
    await t.pumpAndSettle();
  }

  final layer = find.byKey(const ValueKey('video-gestures'));
  final viewer = find.byType(VaultMediaViewerScreen);

  Offset left(WidgetTester t) {
    final r = t.getRect(layer);
    return Offset(r.left + r.width * 0.25, r.top + r.height * 0.4);
  }

  Offset right(WidgetTester t) {
    final r = t.getRect(layer);
    return Offset(r.left + r.width * 0.75, r.top + r.height * 0.4);
  }

  Future<void> doubleTap(WidgetTester t, Offset at) async {
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 80));
    await t.tapAt(at);
    await t.pump();
  }

  double chromeOpacity(WidgetTester t) => t
      .widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('video-seek')),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      )
      .opacity;

  double zoomScale(WidgetTester t) => t
      .widget<InteractiveViewer>(find.byKey(const ValueKey('video-zoom')))
      .transformationController!
      .value
      .getMaxScaleOnAxis();

  Future<void> settleTimers(WidgetTester t) async {
    await t.pump(kVideoSkipStreak + const Duration(milliseconds: 100));
    await t.pumpAndSettle();
  }

  testWidgets('doble toque derecha = +10 s; izquierda = −10 s', (t) async {
    await pumpViewer(t);
    await doubleTap(t, right(t));
    expect(platform.seeks.last, const Duration(seconds: 10));
    await settleTimers(t);
    await doubleTap(t, left(t));
    expect(platform.seeks.last, Duration.zero);
    await settleTimers(t);
  });

  testWidgets('toques seguidos acumulan +10, +20, +30 con indicador', (
    t,
  ) async {
    await pumpViewer(t);
    await doubleTap(t, right(t));
    expect(find.text('+10 s'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(right(t));
    await t.pump();
    expect(platform.seeks.last, const Duration(seconds: 20));
    expect(find.text('+20 s'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(right(t));
    await t.pump();
    expect(platform.seeks.last, const Duration(seconds: 30));
    expect(find.text('+30 s'), findsOneWidget);
    expect(platform.seeks, [
      const Duration(seconds: 10),
      const Duration(seconds: 20),
      const Duration(seconds: 30),
    ]);
    expect(haptics, 3);
    // Sin más toques el indicador desaparece y la racha termina.
    await settleTimers(t);
    expect(find.text('+30 s'), findsNothing);
  });

  testWidgets('cambiar de lado reinicia la racha desde la posición actual', (
    t,
  ) async {
    await pumpViewer(t);
    await doubleTap(t, right(t));
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(right(t)); // 20 s
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(left(t)); // racha nueva hacia atrás: 20 - 10
    await t.pump();
    expect(platform.seeks.last, const Duration(seconds: 10));
    expect(find.text('−10 s'), findsOneWidget);
    await settleTimers(t);
  });

  testWidgets('respeta el inicio: -10 s en 0:00 no hace nada', (t) async {
    await pumpViewer(t);
    await doubleTap(t, left(t));
    expect(platform.seeks, isEmpty);
    expect(find.textContaining('−'), findsNothing);
    expect(haptics, 0);
    await settleTimers(t);
  });

  testWidgets('respeta el final: el salto se acota a la duración', (t) async {
    platform.duration = const Duration(seconds: 25);
    await pumpViewer(t);
    await doubleTap(t, right(t));
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(right(t));
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(right(t)); // ya en 25 s: no suma ni busca de nuevo
    await t.pump();
    expect(
      platform.seeks,
      [
        const Duration(seconds: 10),
        const Duration(seconds: 20),
        const Duration(seconds: 25),
      ].sublist(0, 3),
    );
    expect(find.text('+25 s'), findsOneWidget);
    await settleTimers(t);
    expect(platform.seeks.length, 3);
  });

  testWidgets('toque simple muestra/oculta los controles (tras 300 ms)', (
    t,
  ) async {
    await pumpViewer(t);
    expect(chromeOpacity(t), 1);
    await t.tapAt(right(t));
    await t.pump(const Duration(milliseconds: 100));
    expect(chromeOpacity(t), 1); // aún espera un posible segundo toque
    await t.pump(kVideoDoubleTap);
    await t.pumpAndSettle();
    expect(chromeOpacity(t), 0);
    expect(platform.seeks, isEmpty);
    await t.tapAt(right(t));
    await t.pump(kVideoDoubleTap + const Duration(milliseconds: 50));
    await t.pumpAndSettle();
    expect(chromeOpacity(t), 1);
  });

  testWidgets('el doble toque NO hace zoom en video', (t) async {
    await pumpViewer(t);
    await doubleTap(t, right(t));
    await settleTimers(t);
    expect(zoomScale(t), 1);
  });

  testWidgets('los controles siguen respondiendo (pausar y barra)', (t) async {
    await pumpViewer(t);
    await t.tap(find.byTooltip('Pausar'));
    await t.pump();
    expect(platform.calls, contains('pause'));
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
    expect(platform.seeks, isEmpty); // tocar un botón no es un salto
    await settleTimers(t);
  });

  Future<void> pinchOut(WidgetTester t) async {
    final c = t.getCenter(layer);
    final g1 = await t.startGesture(c - const Offset(20, 0), pointer: 1);
    final g2 = await t.startGesture(c + const Offset(20, 0), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await g1.moveBy(const Offset(-14, 0));
      await g2.moveBy(const Offset(14, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
  }

  testWidgets('pellizco amplía hasta 4x como máximo', (t) async {
    await pumpViewer(t);
    await pinchOut(t);
    final z = zoomScale(t);
    expect(z, greaterThan(1.05));
    expect(z, lessThanOrEqualTo(kVideoMaxScale + 0.001));
  });

  testWidgets('con zoom: arrastrar mueve la imagen, no cierra ni pagina', (
    t,
  ) async {
    await pumpViewer(
      t,
      list: [
        fakeItem('3', name: 'tres.mp4', mime: 'video/mp4'),
        fakeItem('4', name: 'cuatro.mp4', mime: 'video/mp4'),
      ],
    );
    await pinchOut(t);
    expect(zoomScale(t), greaterThan(1.05));
    final before = t
        .widget<InteractiveViewer>(find.byKey(const ValueKey('video-zoom')))
        .transformationController!
        .value
        .getTranslation();
    // Arrastre vertical largo: no cierra.
    final g = await t.startGesture(t.getCenter(layer));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, 40));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pump(const Duration(seconds: 1));
    await g.up();
    await t.pumpAndSettle();
    expect(viewer, findsOneWidget);
    // Arrastre horizontal: tampoco cambia de página.
    await t.fling(layer, const Offset(-300, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('tres.mp4'), findsOneWidget);
    expect(find.textContaining('2 / 2'), findsNothing);
    final after = t
        .widget<InteractiveViewer>(find.byKey(const ValueKey('video-zoom')))
        .transformationController!
        .value
        .getTranslation();
    expect(after, isNot(before)); // la imagen se movió
  });

  testWidgets('a 1x todo sigue igual: cerrar deslizando y paginar', (t) async {
    await pumpViewer(
      t,
      list: [
        fakeItem('3', name: 'tres.mp4', mime: 'video/mp4'),
        fakeItem('4', name: 'cuatro.mp4', mime: 'video/mp4'),
      ],
    );
    await t.fling(layer, const Offset(-400, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('cuatro.mp4'), findsOneWidget);
    await t.fling(
      find.byKey(const ValueKey('viewer-pages')),
      const Offset(0, 120),
      2500,
    );
    await t.pumpAndSettle();
    expect(viewer, findsNothing);
  });

  testWidgets('liberar el video con zoom devuelve el visor a 1x', (t) async {
    await pumpViewer(
      t,
      list: [
        fakeItem('3', name: 'tres.mp4', mime: 'video/mp4'),
        fakeItem('4', name: 'cuatro.mp4', mime: 'video/mp4'),
      ],
    );
    await pinchOut(t);
    // Segundo plano: el origen se libera (idle) estando ampliado.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await t.pumpAndSettle();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    // Ya se puede paginar (no quedó "zoomed" atascado).
    await t.fling(
      find.byKey(const ValueKey('viewer-pages')),
      const Offset(-400, 0),
      1500,
    );
    await t.pumpAndSettle();
    expect(find.text('cuatro.mp4'), findsOneWidget);
  });
}
