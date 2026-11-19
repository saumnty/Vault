// Fase 4 (v2): Guardar en Fotos. Descifra a un temporal, entrega a la
// fototeca y borra el temporal SIEMPRE.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/gallery/photo_saver.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/vault/vault_media_viewer_screen.dart';
import 'package:vault/features/vault/viewer/media_exporter.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';

import 'support/f6_env.dart';
import 'support/ui_helpers.dart';

class FakeSaver implements PhotoSaver {
  bool allow = true;
  Object? failWith;
  int permissionAsks = 0;
  final saved = <String>[];
  Uint8List? lastBytes;
  String? lastPath;
  bool tempExistedAtSave = false;

  @override
  Future<bool> requestAddPermission() async {
    permissionAsks++;
    return allow;
  }

  @override
  Future<void> openSettings() async {}

  Future<void> _save(File f, String filename, String kind) async {
    if (failWith != null) throw failWith!;
    lastPath = f.path;
    tempExistedAtSave = f.existsSync();
    lastBytes = await f.readAsBytes();
    saved.add('$kind:$filename');
  }

  @override
  Future<void> saveImage(File file, {required String filename}) =>
      _save(file, filename, 'img');

  @override
  Future<void> saveVideo(File file, {required String filename}) =>
      _save(file, filename, 'vid');
}

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

class _Spy implements MediaExporter {
  int calls = 0;
  ExportOutcome outcome = ExportOutcome.saved;

  @override
  Future<ExportOutcome> export(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  }) async {
    calls++;
    return outcome;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F6Env env;
  late PlainTempManager temp;
  late VaultMediaOpener opener;
  late FakeSaver saver;
  late VaultMediaExporter exporter;

  List<FileSystemEntity> leftovers() => AppPaths.tmpPlainDir.existsSync()
      ? AppPaths.tmpPlainDir.listSync()
      : const [];

  group('VaultMediaExporter', () {
    setUp(() async {
      env = F6Env();
      await env.setUp();
      temp = PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir);
      opener = VaultMediaOpener(
        fetcher: env.fetcher,
        filesKey: env.session.filesKeyFor,
        temp: temp,
        streaming: false,
      );
      saver = FakeSaver();
      exporter = VaultMediaExporter(opener: opener, saver: saver);
    });
    tearDown(() => env.tearDown());

    test('foto: entrega los bytes EXACTOS y borra el temporal', () async {
      final plain = _bytes(2 * 1024 * 1024 + 77);
      final item = await env.addCloudItem('a', plain: plain, name: 'v.jpg');
      final r = await exporter.export(item);
      expect(r, ExportOutcome.saved);
      expect(saver.saved, ['img:v.jpg']);
      expect(saver.tempExistedAtSave, isTrue);
      expect(saver.lastBytes, plain);
      expect(File(saver.lastPath!).existsSync(), isFalse);
      expect(leftovers(), isEmpty);
      expect(temp.activeCount, 0);
    });

    test('video: usa saveVideo con la extensión original', () async {
      final item = await env.addCloudItem(
        'b',
        plain: _bytes(1500),
        name: 'clip.mov',
        mime: 'video/quicktime',
      );
      expect(await exporter.export(item), ExportOutcome.saved);
      expect(saver.saved, ['vid:clip.mov']);
      expect(saver.lastPath, endsWith('.mov'));
      expect(leftovers(), isEmpty);
    });

    test('permiso denegado: no descifra nada ni deja temporales', () async {
      final item = await env.addCloudItem('c', plain: _bytes(500));
      saver.allow = false;
      expect(await exporter.export(item), ExportOutcome.permissionDenied);
      expect(saver.saved, isEmpty);
      expect(saver.permissionAsks, 1);
      expect(leftovers(), isEmpty);
    });

    test('fallo al guardar: reporta error y borra el temporal', () async {
      final item = await env.addCloudItem('d', plain: _bytes(500));
      saver.failWith = const FileSystemException('x');
      expect(await exporter.export(item), ExportOutcome.failed);
      expect(leftovers(), isEmpty);
      expect(temp.activeCount, 0);
    });

    test('bóveda bloqueada: no guarda y no deja temporales', () async {
      final item = await env.addCloudItem('e', plain: _bytes(500));
      env.session.clear();
      expect(await exporter.export(item), ExportOutcome.cancelledByLock);
      expect(saver.saved, isEmpty);
      expect(leftovers(), isEmpty);
    });

    test('un archivo que no es foto ni video no se exporta', () async {
      final item = await env.addCloudItem(
        'f',
        plain: _bytes(100),
        name: 'doc.pdf',
        mime: 'application/pdf',
      );
      expect(MediaExporter.canExport(item), isFalse);
      expect(await exporter.export(item), ExportOutcome.unsupported);
      expect(saver.permissionAsks, 0);
    });
  });

  group('visor: acción Guardar en Fotos', () {
    late Uint8List png;

    Future<_Spy> pump(WidgetTester t, {bool withExporter = true}) async {
      await t.runAsync(() async {
        png = await makeThumbPng(
          const Color(0xFF7C3AED),
          const Color(0xFFFBBF24),
          size: 200,
        );
      });
      final spy = _Spy();
      usePhoneSize(t);
      await t.pumpWidget(
        testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VaultMediaViewerScreen(
                    items: [fakeItem('1', name: 'uno.jpg')],
                    initialIndex: 0,
                    mediaOpener: FakeMediaOpener(images: {'1': png}),
                    mediaExporter: withExporter ? spy : null,
                    session: VaultSession.create(),
                  ),
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await t.tap(find.text('abrir'));
      await t.pumpAndSettle();
      return spy;
    }

    testWidgets('advierte que la copia queda SIN cifrar; cancelar no guarda', (
      t,
    ) async {
      final spy = await pump(t);
      await t.tap(find.byTooltip('Guardar en Fotos'));
      await t.pumpAndSettle();
      expect(find.textContaining('SIN cifrar'), findsOneWidget);
      await t.tap(find.text('Cancelar'));
      await t.pumpAndSettle();
      expect(spy.calls, 0);
    });

    testWidgets('confirmar guarda y avisa', (t) async {
      final spy = await pump(t);
      await t.tap(find.byTooltip('Guardar en Fotos'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(spy.calls, 1);
      expect(find.text('Guardado en Fotos (sin cifrar).'), findsOneWidget);
    });

    testWidgets('permiso denegado: mensaje claro', (t) async {
      final spy = await pump(t);
      spy.outcome = ExportOutcome.permissionDenied;
      await t.tap(find.byTooltip('Guardar en Fotos'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(find.textContaining('Sin permiso'), findsOneWidget);
    });

    testWidgets('sin exportador no hay botón', (t) async {
      await pump(t, withExporter: false);
      expect(find.byTooltip('Guardar en Fotos'), findsNothing);
    });
  });
}
