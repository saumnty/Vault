// ignore_for_file: depend_on_referenced_packages
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
  late Uint8List png;

  setUp(() {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
  });

  final items = [
    fakeItem('1', name: 'uno.jpg'),
    fakeItem('2', name: 'dos.jpg'),
  ];

  Future<void> pumpViewer(
    WidgetTester tester,
    MediaOpener opener, {
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
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  Future<FakeMediaOpener> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      png = await makeThumbPng(
        const Color(0xFF7C3AED),
        const Color(0xFFFBBF24),
        size: 400,
      );
    });
    final opener = FakeMediaOpener(images: {'1': png, '2': png});
    await pumpViewer(tester, opener);
    return opener;
  }

  double bgAlpha(WidgetTester tester) => tester
      .widget<Scaffold>(find.byKey(const ValueKey('viewer-scaffold')))
      .backgroundColor!
      .a;

  final photo = find.byKey(const ValueKey('photo-zoom'));
  final viewer = find.byType(VaultMediaViewerScreen);

  Future<void> drag(WidgetTester tester, Offset at, Offset by) async {
    final g = await tester.startGesture(at);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(by / 10);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
  }

  testWidgets('arrastre corto hacia abajo: vuelve y el visor sigue', (
    tester,
  ) async {
    await open(tester);
    final g = await tester.startGesture(tester.getCenter(photo));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(bgAlpha(tester), lessThan(1));
    await tester.pump(const Duration(seconds: 1)); // sin velocidad al soltar
    await g.up();
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);
    expect(bgAlpha(tester), 1);
  });

  testWidgets('arrastre largo hacia abajo cierra el visor', (tester) async {
    await open(tester);
    final g = await tester.startGesture(tester.getCenter(photo));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(seconds: 1));
    await g.up();
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(find.text('abrir'), findsOneWidget);
  });

  testWidgets('fling rápido hacia abajo (corto) cierra el visor', (
    tester,
  ) async {
    await open(tester);
    await tester.fling(photo, const Offset(0, 70), 2000);
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
  });

  testWidgets('la opacidad del fondo baja con la distancia', (tester) async {
    await open(tester);
    final g = await tester.startGesture(tester.getCenter(photo));
    await g.moveBy(const Offset(0, 25));
    await tester.pump();
    await g.moveBy(const Offset(0, 25));
    await tester.pump();
    final a1 = bgAlpha(tester);
    await g.moveBy(const Offset(0, 60));
    await tester.pump();
    final a2 = bgAlpha(tester);
    expect(a1, lessThan(1));
    expect(a2, lessThan(a1));
    await g.cancel();
    await tester.pumpAndSettle();
    expect(bgAlpha(tester), 1);
  });

  testWidgets('con zoom activo el arrastre vertical no cierra', (tester) async {
    await open(tester);
    final c = tester.getCenter(photo);
    await tester.tapAt(c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    await drag(tester, c, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);
    expect(bgAlpha(tester), 1);
  });

  testWidgets('arrastre horizontal sigue cambiando de página', (tester) async {
    await open(tester);
    await tester.fling(
      find.byKey(const ValueKey('viewer-pages')),
      const Offset(-400, 0),
      1500,
    );
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);
    expect(find.text('dos.jpg'), findsOneWidget);
    expect(find.textContaining('2 / 2'), findsOneWidget);
  });

  testWidgets('arrastre hacia arriba no cierra', (tester) async {
    await open(tester);
    await drag(tester, tester.getCenter(photo), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);
  });

  testWidgets('video: el arrastre que empieza sobre los controles no cierra', (
    tester,
  ) async {
    final opener = FakeMediaOpener()..videoFactory = (i) => _FakeSource();
    await pumpViewer(
      tester,
      opener,
      list: [fakeItem('3', name: 'tres.mp4', mime: 'video/mp4')],
    );
    await tester.tap(find.byKey(const ValueKey('video-play')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);

    await drag(
      tester,
      tester.getCenter(find.byTooltip('Pausar')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);

    // Fuera de los controles sí cierra.
    await drag(
      tester,
      tester.getCenter(find.byType(VideoPlayer)),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
  });
}
