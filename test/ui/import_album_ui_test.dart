// v2.2 (D86): UI de «Importar de galería» con álbumes, «Seleccionar todo»,
// destino, aviso previo, progreso de la cola y resumen.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/data/gallery/gallery_album_source.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/data/gallery/import_queue_repository.dart';
import 'package:vault/data/gallery/import_queue_service.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/features/gallery/gallery_import_screen.dart';
import 'package:vault/features/gallery/gallery_picker_screen.dart';
import 'package:vault/features/gallery/import_queue_sheet.dart';

import '../support/ui_helpers.dart';

class _Albums implements GalleryAlbumSource {
  final Map<String, List<GalleryAsset>> data = {
    'all': [
      for (var i = 0; i < 6; i++)
        GalleryAsset(id: 'p$i', type: GalleryAssetType.image),
    ],
    'viaje': [
      for (var i = 0; i < 4; i++)
        GalleryAsset(id: 'v$i', type: GalleryAssetType.image),
    ],
  };

  @override
  Future<List<GalleryAlbum>> listAlbums() async => [
    GalleryAlbum(id: 'all', name: 'Recientes', count: 6, isAll: true),
    GalleryAlbum(id: 'viaje', name: 'Viaje', count: 4),
  ];

  @override
  Future<List<GalleryAsset>> listAlbumAssets(
    String albumId, {
    required int page,
    required int size,
  }) async {
    final l = data[albumId]!;
    final s = page * size;
    if (s >= l.length) return const [];
    return l.sublist(s, s + size > l.length ? l.length : s + size);
  }

  @override
  Future<GalleryAsset?> assetById(String id) async => null;
  @override
  Future<GalleryPermission> requestPermission() async =>
      GalleryPermission.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<int> assetCount() async => 6;
  @override
  Future<List<GalleryAsset>> listAssets({
    required int page,
    required int size,
  }) async => const [];
  @override
  Future<bool> isLocallyAvailable(String id) async => true;
  @override
  Future<OriginFile?> originFile(
    String id, {
    bool allowNetwork = false,
    void Function(double)? onProgress,
  }) async => null;
  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async => null;
  @override
  Future<List<String>> deleteAssets(List<String> ids) async => const [];
  @override
  Future<void> clearPlainCaches() async {}
}

class _NoCompress implements VideoCompressor {
  @override
  Future<CompressedVideo?> compress(
    _,
    VideoQualityOption q, {
    void Function(double)? onProgress,
  }) async => null;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> cleanup() async {}
}

Widget _opener(Future<void> Function(BuildContext) open) => Builder(
  builder: (context) => TextButton(
    onPressed: () => open(context),
    child: const Text('abrir'),
  ),
);

void main() {
  sqfliteFfiInit();

  testWidgets('pestaña Álbumes: lista con conteo e «Importar los N»', (
    tester,
  ) async {
    usePhoneSize(tester);
    GalleryPickResult? result;
    await tester.pumpWidget(
      testApp(
        _opener((c) async {
          result = await Navigator.of(c).push<GalleryPickResult>(
            MaterialPageRoute(
              builder: (_) => GalleryImportScreen(source: _Albums()),
            ),
          );
        }),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Fotos'), findsOneWidget);
    await tester.tap(find.text('Álbumes'));
    await tester.pumpAndSettle();
    expect(find.text('Recientes'), findsOneWidget);
    expect(find.text('Viaje'), findsOneWidget);
    expect(find.text('4 elementos'), findsOneWidget);
    expect(find.bySemanticsLabel('Álbum Viaje, 4 elementos'), findsOneWidget);
    await tester.tap(find.text('Viaje'));
    await tester.pumpAndSettle();
    expect(find.text('4 fotos y videos'), findsOneWidget);
    await tester.tap(find.text('Importar los 4'));
    await tester.pumpAndSettle();
    expect(result!.album!.id, 'viaje');
    expect(result!.allSelected, isTrue);
    expect(result!.fromAlbumList, isTrue);
    expect(result!.count, 4);
  });

  testWidgets('álbum > Elegir: «Seleccionar todo» y quitar uno', (
    tester,
  ) async {
    usePhoneSize(tester);
    GalleryPickResult? result;
    await tester.pumpWidget(
      testApp(
        _opener((c) async {
          result = await Navigator.of(c).push<GalleryPickResult>(
            MaterialPageRoute(
              builder: (_) => GalleryImportScreen(source: _Albums()),
            ),
          );
        }),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Álbumes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Viaje'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elegir'));
    await tester.pumpAndSettle();
    expect(find.text('Seleccionar todo'), findsOneWidget);
    await tester.tap(find.text('Seleccionar todo'));
    await tester.pumpAndSettle();
    expect(find.text('4 seleccionados'), findsOneWidget);
    expect(find.text('Quitar selección'), findsOneWidget);
    expect(find.bySemanticsLabel('Foto 2, seleccionado'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Foto 2, seleccionado'));
    await tester.pumpAndSettle();
    expect(find.text('3 seleccionados'), findsOneWidget);
    await tester.tap(find.text('Importar 3'));
    await tester.pumpAndSettle();
    expect(result!.allSelected, isTrue);
    expect(result!.excluded, {'v1'});
    expect(result!.count, 3);
    expect(result!.fromAlbumList, isTrue);
  });

  testWidgets('pestaña Fotos: «Seleccionar todo» de toda la galería', (
    tester,
  ) async {
    usePhoneSize(tester);
    GalleryPickResult? result;
    await tester.pumpWidget(
      testApp(
        _opener((c) async {
          result = await Navigator.of(c).push<GalleryPickResult>(
            MaterialPageRoute(
              builder: (_) => GalleryImportScreen(source: _Albums()),
            ),
          );
        }),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Seleccionar todo'));
    await tester.pumpAndSettle();
    expect(find.text('6 seleccionados'), findsOneWidget);
    await tester.tap(find.text('Importar 6'));
    await tester.pumpAndSettle();
    expect(result!.album!.isAll, isTrue);
    expect(result!.fromAlbumList, isFalse);
    expect(result!.count, 6);
  });

  testWidgets('destino: carpeta con el nombre del álbum; si existe, pregunta', (
    tester,
  ) async {
    usePhoneSize(tester);
    ImportDestination? dest;
    await tester.pumpWidget(
      testApp(
        _opener((c) async {
          dest = await showAlbumDestinationSheet(
            c,
            albumName: 'Viaje',
            currentFolderName: 'Mi Bóveda',
            siblingNames: const ['viaje', 'Otra'],
          );
        }),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Usar la carpeta «Viaje» que ya existe'), findsOneWidget);
    expect(find.text('Carpeta nueva «Viaje (2)»'), findsOneWidget);
    expect(find.text('Carpeta actual «Mi Bóveda»'), findsOneWidget);
    await tester.tap(find.text('Carpeta nueva «Viaje (2)»'));
    await tester.pumpAndSettle();
    expect(dest!.kind, ImportDestinationKind.newFolder);
    expect(dest!.folderName, 'Viaje (2)');
    expect(freeFolderName('A', ['a', 'A (2)']), 'A (3)');
    expect(freeFolderName('B', ['a']), 'B');
  });

  testWidgets('aviso previo: sin espacio y datos móviles', (tester) async {
    usePhoneSize(tester);
    var go = false;
    await tester.pumpWidget(
      testApp(
        _opener((c) async {
          go = await showImportPreflightSheet(
            c,
            preflight: const ImportPreflight(
              batchId: 'b',
              total: 250,
              estimatedBytes: 900 * 1024 * 1024,
              neededBytes: 1100 * 1024 * 1024,
              freeBytes: 500 * 1024 * 1024,
              cellular: true,
            ),
          );
        }),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Importar 250 elementos'), findsOneWidget);
    expect(find.textContaining('Puede que no haya espacio'), findsOneWidget);
    expect(find.textContaining('datos móviles'), findsOneWidget);
    await tester.tap(find.text('Importar de todos modos'));
    await tester.pumpAndSettle();
    expect(go, isTrue);
  });

  group('hoja de la cola', () {
    late Database db;
    late ImportQueueService service;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: VaultSchema.version,
          onCreate: (d, v) => VaultSchema.create(d),
        ),
      );
      final src = _Albums();
      service = ImportQueueService(
        importer: GalleryImportService(
          source: src,
          compressor: _NoCompress(),
          repository: VaultDataRepository(dbProvider: () async => db),
          filesKey: () => null,
          thumbsKey: () => null,
          tempDirProvider: () => throw UnimplementedError(),
          isIOS: false,
        ),
        source: src,
        queue: ImportQueueRepository(dbProvider: () async => db),
        isIOS: false,
      );
    });
    tearDown(() async => db.close());

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        testApp(
          _opener((c) => showImportQueueSheet(c, service: service)),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
    }

    testWidgets('en marcha: N de M, etapa, tiempo restante y Pausar', (
      tester,
    ) async {
      usePhoneSize(tester);
      service.status.value = const ImportQueueStatus(
        batchId: 'b',
        state: ImportBatchState.running,
        running: true,
        counts: ImportCounts(pending: 7, running: 1, done: 2),
        stage: ImportStage.downloading,
        fraction: 0.4,
        cellular: true,
        remaining: Duration(minutes: 3),
        lastError: ImportErrorCode.gone,
      );
      await open(tester);
      expect(find.text('Importando 3 de 10'), findsOneWidget);
      expect(
        find.text('Descargando de iCloud por datos móviles 40 %'),
        findsOneWidget,
      );
      expect(find.text('≈ 3 min restantes'), findsOneWidget);
      expect(find.text('Último error: Ya no está en la galería'), findsOneWidget);
      expect(find.text('Pausar'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
    });

    testWidgets('en pausa por espacio: Reanudar / Cancelar / Cerrar', (
      tester,
    ) async {
      usePhoneSize(tester);
      service.status.value = const ImportQueueStatus(
        batchId: 'b',
        state: ImportBatchState.paused,
        counts: ImportCounts(pending: 6, done: 4),
        pauseReason: ImportPauseReason.noSpace,
      );
      await open(tester);
      expect(find.text('Importación en pausa'), findsOneWidget);
      expect(find.textContaining('sin espacio'), findsOneWidget);
      expect(find.text('Reanudar'), findsOneWidget);
      expect(find.text('Cancelar importación'), findsOneWidget);
      await tester.tap(find.text('Cerrar'));
      await tester.pumpAndSettle();
      expect(find.text('Importación en pausa'), findsNothing);
    });

    testWidgets('resumen: importados, ya estaban, con error y motivo; '
        'originales siguen', (tester) async {
      usePhoneSize(tester);
      // sqlite ffi hace E/S real: fuera del reloj falso.
      Future<void> real() => tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.runAsync(() async {
        await db.insert('import_batches', {
          'id': 'b',
          'state': 'finished',
          'videoQuality': 'original',
          'createdAt': 1,
          'updatedAt': 1,
        });
        await db.insert('import_queue', {
          'batchId': 'b',
          'seq': 4,
          'assetId': 'x',
          'state': 'error',
          'error': 'iCloud',
          'name': 'IMG_0004.HEIC',
        });
      });
      service.status.value = const ImportQueueStatus(
        batchId: 'b',
        state: ImportBatchState.finished,
        counts: ImportCounts(done: 7, duplicate: 2, error: 1),
      );
      await tester.pumpWidget(
        testApp(
          _opener((c) => showImportQueueSheet(c, service: service)),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pump();
      await real();
      await tester.pumpAndSettle();
      expect(find.text('Importación terminada con errores'), findsOneWidget);
      expect(
        find.text('7 importado(s) · 2 ya estaban · 1 con error'),
        findsOneWidget,
      );
      expect(
        find.text('IMG_0004.HEIC: No se pudo descargar de iCloud'),
        findsOneWidget,
      );
      expect(find.textContaining('Los originales siguen en tu galería'),
          findsOneWidget);
      await tester.tap(find.text('Listo'));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await real();
      }
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(() => db.query('import_batches')),
        isEmpty,
      );
      expect(find.text('Listo'), findsNothing);
    });
  });

  test('aviso de la cuadrícula', () {
    expect(ImportQueueBanner.textFor(const ImportQueueStatus()), isNull);
    expect(
      ImportQueueBanner.textFor(
        const ImportQueueStatus(
          batchId: 'b',
          state: ImportBatchState.paused,
          counts: ImportCounts(pending: 3, done: 2),
        ),
      ),
      'Importación en pausa: 2 de 5',
    );
    expect(
      ImportQueueBanner.textFor(
        const ImportQueueStatus(
          batchId: 'b',
          state: ImportBatchState.running,
          counts: ImportCounts(pending: 3, done: 2),
        ),
      ),
      'Importando: 2 de 5',
    );
  });
}
