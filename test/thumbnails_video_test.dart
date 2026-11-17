// Miniaturas de VIDEO (ronda iOS 1): el fotograma se extrae del archivo local
// (no depende de la fototeca ni de iCloud), la fototeca queda de respaldo, un
// video sin miniatura muestra ícono + duración y las miniaturas que faltan se
// pueden regenerar. // iOS: la extracción nativa real no se puede probar aquí.
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/data/gallery/thumbnail_regeneration_service.dart';
import 'package:vault/data/gallery/video_thumbnailer.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/features/vault/widgets/thumbnail_view.dart';

import 'gallery_import_service_test.dart' show FakeCompressor, FakeSource;

class FakeThumbnailer implements VideoThumbnailer {
  Uint8List? result = Uint8List.fromList([0xFF, 0xD8, 9, 9, 0xFF, 0xD9]);
  final List<Uint8List> seenPlain = [];
  final List<String> seenPaths = [];
  int calls = 0;

  @override
  Future<Uint8List?> thumbnail(File video, {int size = 256}) async {
    calls++;
    seenPaths.add(video.path);
    seenPlain.add(await video.readAsBytes());
    return result;
  }
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late Directory scratch;
  late Database db;
  late VaultDataRepository repo;
  late KeyHierarchy keys;
  late FakeSource source;
  late FakeThumbnailer thumbnailer;
  final crypto = CryptoService();
  SecretKey? Function() filesKey = () => null;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('thumbs_video_test');
    scratch = Directory('${tmp.path}/src')..createSync();
    await AppPaths.init(baseDir: Directory('${tmp.path}/app'));
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: VaultSchema.version,
        onCreate: (d, v) => VaultSchema.create(d),
      ),
    );
    repo = VaultDataRepository(dbProvider: () async => db);
    keys = await KeyHierarchy.fromDek(
      Uint8List.fromList(List.generate(32, (i) => i + 5)),
    );
    filesKey = () => keys.files;
    source = FakeSource(scratch);
    thumbnailer = FakeThumbnailer();
  });

  tearDown(() async {
    await db.close();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  GalleryImportService importer() => GalleryImportService(
    source: source,
    compressor: FakeCompressor()..outDir = scratch,
    repository: repo,
    filesKey: () => keys.files,
    thumbsKey: () => keys.thumbs,
    tempDirProvider: () => Directory('${tmp.path}/import_tmp'),
    isIOS: false,
    videoThumbnailer: thumbnailer,
  );

  Future<Uint8List> readThumb(VaultItemModel item) async => crypto.decryptBytes(
    await AppPaths.resolve(item.thumbPath!).readAsBytes(),
    keys.thumbs,
    expectedFileId: item.thumbFileId,
  );

  group('importación', () {
    test('video: la miniatura sale del archivo, no de la fototeca', () async {
      final v = source.add('v1', GalleryAssetType.video, 5000, dur: 8);
      source.noThumb.add('v1'); // la fototeca NO tiene miniatura (el caso iOS)
      final res = await importer().importAssets([v], const ImportOptions());
      expect(res.succeeded, 1);
      final item = (await repo.getItem(res.items.single.itemId!))!;
      expect(item.thumbPath, isNotNull);
      expect(item.thumbFileId, isNotNull);
      expect(await readThumb(item), thumbnailer.result);
      // Se le entregó el contenido real del video.
      expect(thumbnailer.seenPlain.single, source.contents['v1']);
    });

    test('video: si el fotograma falla, se usa la fototeca', () async {
      thumbnailer.result = null;
      final v = source.add('v1', GalleryAssetType.video, 5000, dur: 8);
      final res = await importer().importAssets([v], const ImportOptions());
      final item = (await repo.getItem(res.items.single.itemId!))!;
      expect(item.thumbPath, isNotNull);
      expect(await readThumb(item), [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
    });

    test(
      'video solo en iCloud: igualmente miniatura del archivo bajado',
      () async {
        final v = source.add('v1', GalleryAssetType.video, 5000, dur: 8);
        source.remoteOnly.add('v1');
        source.noThumb.add('v1');
        final svc = GalleryImportService(
          source: source,
          compressor: FakeCompressor()..outDir = scratch,
          repository: repo,
          filesKey: () => keys.files,
          thumbsKey: () => keys.thumbs,
          tempDirProvider: () => Directory('${tmp.path}/import_tmp'),
          isIOS: true,
          videoThumbnailer: thumbnailer,
        );
        final res = await svc.importAssets([v], const ImportOptions());
        expect(res.succeeded, 1);
        expect(source.originRequests, ['v1:true']);
        final item = (await repo.getItem(res.items.single.itemId!))!;
        expect(item.thumbPath, isNotNull);
      },
    );

    test(
      'video sin ninguna miniatura: se importa igual, thumbPath nulo',
      () async {
        thumbnailer.result = null;
        final v = source.add('v1', GalleryAssetType.video, 5000, dur: 8);
        source.noThumb.add('v1');
        final res = await importer().importAssets([v], const ImportOptions());
        expect(res.succeeded, 1);
        final item = (await repo.getItem(res.items.single.itemId!))!;
        expect(item.thumbPath, isNull);
        expect(item.durationMs, 8000);
      },
    );

    test('foto: no usa el extractor de video', () async {
      final a = source.add('p1', GalleryAssetType.image, 3000);
      await importer().importAssets([a], const ImportOptions());
      expect(thumbnailer.calls, 0);
    });
  });

  group('regeneración de miniaturas', () {
    ThumbnailRegenerationService regen({
      SecretKey? Function()? thumbs,
      int maxPerRun = 40,
      int autoMax = 100 * 1024 * 1024,
    }) => ThumbnailRegenerationService(
      repository: repo,
      source: source,
      videoThumbnailer: thumbnailer,
      filesKey: filesKey,
      thumbsKey: thumbs ?? () => keys.thumbs,
      tempDirProvider: () => Directory('${tmp.path}/import_tmp'),
      maxPerRun: maxPerRun,
      autoMaxDecryptBytes: autoMax,
    );

    /// Item de video con `.vault` real y SIN miniatura.
    Future<VaultItemModel> videoWithoutThumb(
      String id, {
      required Uint8List plain,
      String? assetId,
      bool keepVault = true,
      bool withFileId = true,
    }) async {
      final rel = AppPaths.vaultRelativePath(id);
      final src = File('${scratch.path}/$id.plain')..writeAsBytesSync(plain);
      final header = await crypto.encryptFile(
        src,
        AppPaths.resolve(rel),
        keys.files,
      );
      if (!keepVault) AppPaths.resolve(rel).deleteSync();
      await repo.insertItem(
        VaultItemModel(
          keyGen: 1,
          id: id,
          name: '$id.mov',
          encryptedPath: rel,
          fileSize: plain.length,
          mimeType: 'video/quicktime',
          createdAt: '2026-05-01T00:00:00',
          sourceAssetId: assetId,
          durationMs: 4000,
          fileId: withFileId ? header.fileIdString : null,
        ),
      );
      return (await repo.getItem(id))!;
    }

    test('desde la fototeca si el original sigue ahí', () async {
      final item = await videoWithoutThumb(
        'a1',
        plain: Uint8List.fromList(List.filled(100, 3)),
        assetId: 'asset1',
      );
      final r = await regen().run();
      expect(r.regenerated, 1);
      final after = (await repo.getItem(item.id))!;
      expect(after.thumbPath, AppPaths.thumbRelativePath('a1'));
      expect(after.thumbDriveFileId, isNull); // se subirá
      expect(await readThumb(after), [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
      expect(thumbnailer.calls, 0);
    });

    test('sin original en la fototeca: fotograma del .vault local, '
        'temporal borrado', () async {
      final plain = Uint8List.fromList(List.generate(2000, (i) => i % 200));
      final item = await videoWithoutThumb(
        'a2',
        plain: plain,
        assetId: 'borrado',
      );
      source.noThumb.add('borrado');
      final r = await regen().run();
      expect(r.regenerated, 1);
      expect(thumbnailer.seenPlain.single, plain); // contenido en claro
      // El temporal en claro no queda en disco.
      final leftovers = Directory('${tmp.path}/import_tmp').existsSync()
          ? Directory('${tmp.path}/import_tmp').listSync(recursive: true)
          : <FileSystemEntity>[];
      expect(leftovers.whereType<File>(), isEmpty);
      final after = (await repo.getItem(item.id))!;
      expect(await readThumb(after), thumbnailer.result);
    });

    test('video que solo está en la nube no se descarga solo', () async {
      await videoWithoutThumb(
        'a3',
        plain: Uint8List.fromList(List.filled(100, 1)),
        keepVault: false,
      );
      final r = await regen().run();
      expect(r.regenerated, 0);
      expect(r.failed, 1);
      expect(thumbnailer.calls, 0);
    });

    test('.vault con otro fileId (S-09) no se usa', () async {
      final item = await videoWithoutThumb(
        'a4',
        plain: Uint8List.fromList(List.filled(100, 1)),
      );
      await db.update(
        'vault_items',
        {'fileId': '00000000-0000-4000-8000-000000000000'},
        where: 'id = ?',
        whereArgs: [item.id],
      );
      final r = await regen().run();
      expect(r.regenerated, 0);
      expect(thumbnailer.calls, 0);
    });

    test('automática: no descifra videos grandes; manual sí', () async {
      await videoWithoutThumb(
        'a5',
        plain: Uint8List.fromList(List.filled(5000, 1)),
      );
      final auto = await regen(autoMax: 1000).run();
      expect(auto.regenerated, 0);
      expect(thumbnailer.calls, 0);
      // Manual: ignora el tope Y reintenta los que fallaron antes.
      final manual = await regen(autoMax: 1000).run(manual: true);
      expect(manual.regenerated, 1);
    });

    test('lo que falló no se reintenta en cada pasada automática', () async {
      thumbnailer.result = null;
      await videoWithoutThumb(
        'a6',
        plain: Uint8List.fromList(List.filled(100, 1)),
      );
      final svc = regen();
      expect((await svc.run()).failed, 1);
      expect(thumbnailer.calls, 1);
      expect((await svc.run()).candidates, 0); // recordado
      expect(thumbnailer.calls, 1);
      expect((await svc.run(manual: true)).candidates, 1); // manual reintenta
    });

    test('tope por pasada automática', () async {
      for (var i = 0; i < 5; i++) {
        await videoWithoutThumb(
          'b$i',
          plain: Uint8List.fromList(List.filled(100, 1)),
          assetId: 'x$i',
        );
      }
      final r = await regen(maxPerRun: 2).run();
      expect(r.candidates, 2);
      expect(await regen().countMissing(), 3);
    });

    test('bloqueada: no hace nada y no lanza', () async {
      await videoWithoutThumb(
        'a7',
        plain: Uint8List.fromList(List.filled(100, 1)),
        assetId: 's',
      );
      final r = await regen(thumbs: () => null).run();
      expect(r.candidates, 0);
      expect(await regen().countMissing(), 1);
    });

    test('miniatura registrada pero con el archivo perdido también se '
        'regenera', () async {
      final item = await videoWithoutThumb(
        'c1',
        plain: Uint8List.fromList(List.filled(100, 2)),
        assetId: 'asset-c1',
      );
      await regen().run(); // la crea
      final path = AppPaths.resolve(AppPaths.thumbRelativePath(item.id));
      expect(path.existsSync(), isTrue);
      path.deleteSync(); // se pierde el archivo local
      expect(await regen().countMissing(), 1);
      final r = await regen().run(manual: true);
      expect(r.regenerated, 1);
      expect(path.existsSync(), isTrue);
    });

    test('los que no son foto/video no cuentan', () async {
      await repo.insertItem(
        const VaultItemModel(
          keyGen: 1,
          id: 'doc1',
          name: 'notas.pdf',
          encryptedPath: 'vault/doc1.vault',
          fileSize: 1,
          mimeType: 'application/pdf',
          createdAt: '2026-05-01T00:00:00',
        ),
      );
      expect(await regen().countMissing(), 0);
    });
  });

  group('respaldo visible', () {
    Widget host(VaultItemModel item) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 200,
          child: ThumbnailView(item: item, loader: (_) async => null),
        ),
      ),
    );

    testWidgets('video sin miniatura: ícono de video y duración', (t) async {
      await t.pumpWidget(
        host(
          const VaultItemModel(
            keyGen: 1,
            id: 'v',
            name: 'clip.mov',
            encryptedPath: 'vault/v.vault',
            fileSize: 1,
            mimeType: 'video/quicktime',
            createdAt: '2026-05-01T00:00:00',
            durationMs: 125000,
          ),
        ),
      );
      await t.pump();
      expect(find.text('2:05'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('foto sin miniatura: sin insignia de video', (t) async {
      await t.pumpWidget(
        host(
          const VaultItemModel(
            keyGen: 1,
            id: 'p',
            name: 'foto.jpg',
            encryptedPath: 'vault/p.vault',
            fileSize: 1,
            mimeType: 'image/jpeg',
            createdAt: '2026-05-01T00:00:00',
          ),
        ),
      );
      await t.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });
  });
}
