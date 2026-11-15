import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/features/vault/services/thumbnail_loader.dart';

class FakeSource implements GalleryAssetSource {
  FakeSource(this.dir);
  final Directory dir;
  final Map<String, Uint8List> contents = {};
  final Set<String> missing = {};
  final Set<String> remoteOnly = {};
  final Set<String> throwOn = {};
  final Set<String> noThumb = {};
  final List<String> deleted = [];
  final List<String> originRequests = [];
  int cacheClears = 0;
  bool temporary = true;
  void Function(String id)? onOrigin;

  GalleryAsset add(String id, GalleryAssetType type, int size, {int dur = 0}) {
    contents[id] = Uint8List.fromList(
      List.generate(size, (i) => (i * 7) % 251),
    );
    return GalleryAsset(
      id: id,
      type: type,
      title: type == GalleryAssetType.video ? '$id.mp4' : '$id.jpg',
      duration: Duration(seconds: dur),
    );
  }

  @override
  Future<GalleryPermission> requestPermission() async =>
      GalleryPermission.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<int> assetCount() async => contents.length;
  @override
  Future<List<GalleryAsset>> listAssets({
    required int page,
    required int size,
  }) async => const [];
  @override
  Future<bool> isLocallyAvailable(String id) async => !remoteOnly.contains(id);
  @override
  Future<OriginFile?> originFile(
    String id, {
    bool allowNetwork = false,
    void Function(double)? onProgress,
  }) async {
    originRequests.add('$id:$allowNetwork');
    onOrigin?.call(id);
    if (throwOn.contains(id)) throw StateError('boom $id');
    if (missing.contains(id)) return null;
    onProgress?.call(0.5);
    final f = File('${dir.path}/origin_$id.bin')
      ..writeAsBytesSync(contents[id]!);
    return OriginFile(f, isTemporary: temporary);
  }

  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async =>
      noThumb.contains(id)
      ? null
      : Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);

  @override
  Future<void> clearPlainCaches() async => cacheClears++;

  @override
  Future<List<String>> deleteAssets(List<String> ids) async {
    deleted.addAll(ids);
    return ids;
  }
}

class FakeCompressor implements VideoCompressor {
  int calls = 0;
  int cleanups = 0;
  int cancels = 0;
  bool fail = false;
  double ratio = 0.5;
  Directory? outDir;

  @override
  Future<CompressedVideo?> compress(
    File source,
    VideoQualityOption quality, {
    void Function(double)? onProgress,
  }) async {
    calls++;
    if (fail) return null;
    final bytes = source.readAsBytesSync();
    final out = File('${outDir!.path}/c_${source.uri.pathSegments.last}')
      ..writeAsBytesSync(bytes.sublist(0, (bytes.length * ratio).round()));
    return CompressedVideo(out, out.lengthSync());
  }

  @override
  Future<void> cancel() async => cancels++;
  @override
  Future<void> cleanup() async => cleanups++;
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late Directory scratch;
  late Database db;
  late VaultDataRepository repo;
  late KeyHierarchy keys;
  late FakeSource source;
  late FakeCompressor compressor;
  final crypto = CryptoService();

  GalleryImportService build({
    bool enabled = false,
    Future<bool> Function()? enabledProvider,
    Future<bool> Function(dynamic)? verifier,
    SecretKey? Function()? files,
  }) => GalleryImportService(
    source: source,
    compressor: compressor,
    repository: repo,
    filesKey: files ?? () => keys.files,
    thumbsKey: () => keys.thumbs,
    tempDirProvider: () => Directory('${tmp.path}/import_tmp'),
    originalDeletionEnabled: enabled,
    deletionEnabledProvider: enabledProvider,
    cloudVerifier: verifier == null ? null : (i) => verifier(i),
    isIOS: false,
  );

  Future<String> sha(Uint8List b) async => (await Sha256().hash(
    b,
  )).bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gallery_import_test');
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
      Uint8List.fromList(List.generate(32, (i) => i + 3)),
    );
    source = FakeSource(scratch);
    compressor = FakeCompressor()..outDir = scratch;
  });

  tearDown(() async {
    await db.close();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('lote con fotos y videos: hash, .vault, miniatura, BD', () async {
    final a = source.add('p1', GalleryAssetType.image, 3000);
    final v = source.add('v1', GalleryAssetType.video, 2500000, dur: 12);
    final svc = build();
    final res = await svc.importAssets([a, v], const ImportOptions());
    expect(res.succeeded, 2);
    expect(res.failed, 0);

    for (final r in res.items) {
      final item = (await repo.getItem(r.itemId!))!;
      final plain = source.contents[item.sourceAssetId]!;
      expect(item.contentHash, await sha(plain));
      expect(item.syncStatus, SyncStatus.pendiente);
      expect(item.fileSize, plain.length);
      expect(item.encryptedPath, 'vault/${item.id}.vault');
      expect(item.thumbPath, 'thumbs/${item.id}.thumb');

      // El .vault descifra al original.
      final out = File('${tmp.path}/out_${item.id}');
      await crypto.decryptFile(
        AppPaths.resolve(item.encryptedPath),
        out,
        keys.files,
      );
      expect(out.readAsBytesSync(), plain);

      // Miniatura: descifra con thumbs y NO con files.
      final enc = AppPaths.resolve(item.thumbPath!).readAsBytesSync();
      expect(await crypto.decryptBytes(enc, keys.thumbs), isNotEmpty);
      await expectLater(
        crypto.decryptBytes(enc, keys.files),
        throwsA(anything),
      );
    }
    final video = (await repo.getItem(res.items[1].itemId!))!;
    expect(video.durationMs, 12000);
    expect(video.mimeType, 'video/mp4');
    expect(compressor.calls, 0); // calidad original
  });

  test('compresión de video: guarda el comprimido y reporta tamaños', () async {
    final v = source.add('v1', GalleryAssetType.video, 10000, dur: 5);
    final svc = build();
    final sizes = <int?>[];
    svc.progress.addListener(() {
      sizes.add(svc.progress.value.compressedBytes);
    });
    final res = await svc.importAssets([
      v,
    ], const ImportOptions(videoQuality: VideoQualityOption.p720));
    final r = res.items.single;
    expect(r.compressed, isTrue);
    expect(r.originalBytes, 10000);
    expect(r.storedBytes, 5000);
    expect(sizes, contains(5000));
    final item = (await repo.getItem(r.itemId!))!;
    expect(item.fileSize, 5000);
    expect(
      item.contentHash,
      await sha(source.contents['v1']!.sublist(0, 5000)),
    );
  });

  test('si la compresión falla se importa el original', () async {
    final v = source.add('v1', GalleryAssetType.video, 4000);
    compressor.fail = true;
    final res = await build().importAssets([
      v,
    ], const ImportOptions(videoQuality: VideoQualityOption.p1080));
    expect(res.items.single.ok, isTrue);
    expect(res.items.single.compressed, isFalse);
    expect(res.items.single.storedBytes, 4000);
  });

  test('un error en un archivo no aborta el lote', () async {
    final a = source.add('a', GalleryAssetType.image, 100);
    final b = source.add('b', GalleryAssetType.image, 100);
    final c = source.add('c', GalleryAssetType.image, 100);
    final d = source.add('d', GalleryAssetType.image, 100);
    source.throwOn.add('b');
    source.missing.add('c');
    final res = await build().importAssets([a, b, c, d], const ImportOptions());
    expect(res.items.map((e) => e.stage), [
      ImportStage.done,
      ImportStage.failed,
      ImportStage.failed,
      ImportStage.done,
    ]);
    expect(res.items[1].error, contains('boom b'));
    expect(res.succeeded, 2);
    expect((await repo.getItemsByFolder(null)).length, 2);
    // Sin huérfanos para los fallidos.
    expect(AppPaths.vaultDir.listSync().length, 2);
  });

  test('miniatura ausente no falla: thumbPath nulo', () async {
    final a = source.add('a', GalleryAssetType.image, 100);
    source.noThumb.add('a');
    final res = await build().importAssets([a], const ImportOptions());
    expect(res.items.single.ok, isTrue);
    expect(res.items.single.thumbnailCreated, isFalse);
    expect((await repo.getItem(res.items.single.itemId!))!.thumbPath, isNull);
    expect(AppPaths.thumbsDir.listSync(), isEmpty);
  });

  test('cancelación: lo restante queda cancelado y sin huérfanos', () async {
    final assets = [
      for (var i = 0; i < 4; i++)
        source.add('x$i', GalleryAssetType.image, 100),
    ];
    final token = ImportCancelToken();
    source.onOrigin = (id) {
      if (id == 'x1') token.cancel(); // se cancela durante el 2.º archivo
    };
    final res = await build().importAssets(
      assets,
      const ImportOptions(),
      cancelToken: token,
    );
    expect(res.cancelled, isTrue);
    expect(res.items.map((e) => e.stage), [
      ImportStage.done,
      ImportStage.cancelled,
      ImportStage.cancelled,
      ImportStage.cancelled,
    ]);
    expect(compressor.cancels, 1);
    expect((await repo.getItemsByFolder(null)).length, 1);
    expect(AppPaths.vaultDir.listSync().length, 1);
    expect(AppPaths.thumbsDir.listSync().length, 1);
  });

  test(
    'limpia temporales (originales temporales, comprimidos, workdir)',
    () async {
      final v = source.add('v1', GalleryAssetType.video, 10000);
      final p = source.add('p1', GalleryAssetType.image, 100);
      source.throwOn.add('zz');
      final svc = build();
      await svc.importAssets([
        v,
        p,
      ], const ImportOptions(videoQuality: VideoQualityOption.p720));
      expect(File('${scratch.path}/origin_v1.bin').existsSync(), isFalse);
      expect(File('${scratch.path}/origin_p1.bin').existsSync(), isFalse);
      expect(File('${scratch.path}/c_origin_v1.bin').existsSync(), isFalse);
      expect(Directory('${tmp.path}/import_tmp').existsSync(), isFalse);
      expect(compressor.cleanups, 1);
    },
  );

  test('NUNCA borra el original no temporal (Android)', () async {
    final a = source.add('a', GalleryAssetType.image, 100);
    source.temporary = false;
    await build().importAssets([a], const ImportOptions());
    expect(File('${scratch.path}/origin_a.bin').existsSync(), isTrue);
    expect(source.deleted, isEmpty);
  });

  test('iOS: original solo en iCloud se pide con red; Android falla', () async {
    final a = source.add('a', GalleryAssetType.image, 100);
    source.remoteOnly.add('a');
    final ios = GalleryImportService(
      source: source,
      compressor: compressor,
      repository: repo,
      filesKey: () => keys.files,
      thumbsKey: () => keys.thumbs,
      tempDirProvider: () => Directory('${tmp.path}/import_tmp'),
      isIOS: true,
    );
    final stages = <ImportStage>[];
    ios.progress.addListener(() => stages.add(ios.progress.value.stage));
    final res = await ios.importAssets([a], const ImportOptions());
    expect(res.items.single.ok, isTrue);
    expect(source.originRequests, ['a:true']);
    expect(stages, contains(ImportStage.downloading));

    source.originRequests.clear();
    final res2 = await build().importAssets([a], const ImportOptions());
    expect(res2.items.single.stage, ImportStage.failed);
    expect(source.originRequests, isEmpty);
  });

  test('bóveda bloqueada: lanza y no hace nada', () async {
    final a = source.add('a', GalleryAssetType.image, 100);
    await expectLater(
      build(files: () => null).importAssets([a], const ImportOptions()),
      throwsStateError,
    );
  });

  group('deleteOriginalsConfirmedInCloud', () {
    Future<void> seed() async {
      final assets = [
        source.add('a', GalleryAssetType.image, 100),
        source.add('b', GalleryAssetType.image, 100),
        source.add('c', GalleryAssetType.image, 100),
      ];
      final res = await build().importAssets(assets, const ImportOptions());
      // a: en nube con driveId; b: en nube SIN driveId; c: pendiente.
      await repo.updateSyncStatus(
        res.items[0].itemId!,
        SyncStatus.enNube,
        driveFileId: 'drv',
      );
      await repo.updateSyncStatus(res.items[1].itemId!, SyncStatus.enNube);
    }

    test('candidatos: solo en_nube con driveFileId', () async {
      await seed();
      final c = await build().deleteOriginalCandidates();
      expect(c.map((e) => e.sourceAssetId), ['a']);
    });

    test('sin confirmación, bandera o verificador no borra nada', () async {
      await seed();
      final cands = await build().deleteOriginalCandidates();
      expect(
        await build(
          enabled: true,
          verifier: (_) async => true,
        ).deleteOriginalsConfirmedInCloud(
          candidates: cands,
          userConfirmed: false,
        ),
        isEmpty,
      );
      expect(
        await build(
          verifier: (_) async => true,
        ).deleteOriginalsConfirmedInCloud(
          candidates: cands,
          userConfirmed: true,
        ),
        isEmpty,
      );
      expect(
        await build(enabled: true).deleteOriginalsConfirmedInCloud(
          candidates: cands,
          userConfirmed: true,
        ),
        isEmpty,
      );
      expect(
        await build(
          enabled: true,
          verifier: (_) async => false,
        ).deleteOriginalsConfirmedInCloud(
          candidates: cands,
          userConfirmed: true,
        ),
        isEmpty,
      );
      expect(source.deleted, isEmpty);
    });

    test('con todo en regla borra solo los elegibles', () async {
      await seed();
      final all = await repo.getItemsByFolder(null);
      final svc = build(enabled: true, verifier: (_) async => true);
      final deleted = await svc.deleteOriginalsConfirmedInCloud(
        candidates: all, // incluye no elegibles: deben ignorarse
        userConfirmed: true,
      );
      expect(source.deleted, ['a']);
      expect(deleted.length, 1);
    });

    test(
      'S-03: tras borrar originales se limpian las cachés del plugin',
      () async {
        await seed();
        final before = source.cacheClears;
        final all = await repo.getItemsByFolder(null);
        await build(
          enabled: true,
          verifier: (_) async => true,
        ).deleteOriginalsConfirmedInCloud(candidates: all, userConfirmed: true);
        expect(source.cacheClears, before + 1);
      },
    );
  });

  group('S-03 cachés en claro del plugin de la galería', () {
    test('cada lote (éxito, error o cancelación) limpia las cachés', () async {
      final a = source.add('p1', GalleryAssetType.image, 100);
      final b = source.add('p2', GalleryAssetType.image, 100);
      source.throwOn.add('p2');
      await build().importAssets([a, b], const ImportOptions());
      expect(source.cacheClears, 1, reason: 'antes del arreglo: 0');

      final token = ImportCancelToken()..cancel();
      await build().importAssets(
        [a],
        const ImportOptions(),
        cancelToken: token,
      );
      expect(source.cacheClears, 2);
    });
  });

  group(
    'borrado de originales: flujo con confirmación (pruebas pendientes)',
    () {
      // Cuatro estados: verificado, pendiente, subiendo, error (y uno en_nube
      // sin md5 que el verificador real rechaza).
      Future<Map<String, String>> seedStates() async {
        final assets = [
          source.add('ok', GalleryAssetType.image, 100),
          source.add('pend', GalleryAssetType.image, 100),
          source.add('sub', GalleryAssetType.image, 100),
          source.add('err', GalleryAssetType.image, 100),
          source.add('nomd5', GalleryAssetType.image, 100),
        ];
        final res = await build().importAssets(assets, const ImportOptions());
        final ids = {
          for (var i = 0; i < assets.length; i++)
            assets[i].id: res.items[i].itemId!,
        };
        await repo.markCloudVerified(
          ids['ok']!,
          driveFileId: 'drv',
          md5: 'abc',
          size: 100,
        );
        await repo.updateSyncStatus(ids['sub']!, SyncStatus.subiendo);
        await repo.updateSyncStatus(ids['err']!, SyncStatus.error);
        await repo.updateSyncStatus(
          ids['nomd5']!,
          SyncStatus.enNube,
          driveFileId: 'drv2',
        );
        return ids;
      }

      // Verificador como el real: exige md5 y tamaño guardados.
      Future<bool> realLike(dynamic i) async =>
          i.cloudMd5 != null && i.cloudSize != null;

      test('apagado por defecto: nada que listar ni borrar', () async {
        await seedStates();
        final svc = build(verifier: realLike); // sin proveedor ni bandera
        expect(await svc.isDeletionEnabled, isFalse);
        expect(await svc.verifiedDeleteCandidates(), isEmpty);
        final all = await repo.getItemsByFolder(null);
        expect(
          await svc.deleteOriginalsConfirmedInCloud(
            candidates: all,
            userConfirmed: true,
          ),
          isEmpty,
        );
        expect(source.deleted, isEmpty);
      });

      test(
        'encendido: solo el verificado; pendiente/subiendo/error/sin md5 no',
        () async {
          final ids = await seedStates();
          final svc = build(
            enabledProvider: () async => true,
            verifier: realLike,
          );
          final listed = await svc.verifiedDeleteCandidates();
          expect(listed.map((e) => e.id), [ids['ok']]);
          final all = await repo.getItemsByFolder(null);
          final deleted = await svc.deleteOriginalsConfirmedInCloud(
            candidates: all,
            userConfirmed: true,
          );
          expect(deleted, [ids['ok']]);
          expect(source.deleted, ['ok']);
        },
      );

      test('cancelar (sin confirmación) no borra nada', () async {
        await seedStates();
        final svc = build(
          enabledProvider: () async => true,
          verifier: realLike,
        );
        final listed = await svc.verifiedDeleteCandidates();
        expect(listed, isNotEmpty);
        expect(
          await svc.deleteOriginalsConfirmedInCloud(
            candidates: listed,
            userConfirmed: false,
          ),
          isEmpty,
        );
        expect(source.deleted, isEmpty);
      });

      test(
        'tras borrar, el item queda intacto y deja de ser candidato',
        () async {
          final ids = await seedStates();
          final svc = build(
            enabledProvider: () async => true,
            verifier: realLike,
          );
          final listed = await svc.verifiedDeleteCandidates();
          await svc.deleteOriginalsConfirmedInCloud(
            candidates: listed,
            userConfirmed: true,
          );
          final item = await repo.getItem(ids['ok']!);
          expect(item, isNotNull);
          expect(item!.syncStatus, SyncStatus.enNube);
          expect(item.sourceAssetId, isNull);
          expect(
            File(AppPaths.resolve(item.encryptedPath).path).existsSync(),
            isTrue,
          );
          expect(await svc.verifiedDeleteCandidates(), isEmpty);
          // Segundo intento: no vuelve a pedir borrar el mismo asset.
          await svc.deleteOriginalsConfirmedInCloud(
            candidates: listed,
            userConfirmed: true,
          );
          expect(source.deleted, ['ok']);
        },
      );

      test(
        'un mismo original importado varias veces se lista y borra una vez',
        () async {
          final a = source.add('dup', GalleryAssetType.image, 100);
          final res = await build().importAssets([a, a], const ImportOptions());
          final ids = [for (final r in res.items) r.itemId!];
          expect(ids, hasLength(2));
          for (final id in ids) {
            await repo.markCloudVerified(
              id,
              driveFileId: 'd$id',
              md5: 'm',
              size: 100,
            );
          }
          final svc = build(
            enabledProvider: () async => true,
            verifier: realLike,
          );
          final listed = await svc.verifiedDeleteCandidates();
          expect(listed, hasLength(1));
          final deleted = await svc.deleteOriginalsConfirmedInCloud(
            candidates: listed,
            userConfirmed: true,
          );
          expect(deleted, hasLength(1));
          expect(source.deleted, ['dup']);
          // Ambos items conservados y ninguno vuelve a ser candidato.
          for (final id in ids) {
            final it = await repo.getItem(id);
            expect(it, isNotNull);
            expect(it!.sourceAssetId, isNull);
          }
          expect(await svc.verifiedDeleteCandidates(), isEmpty);
        },
      );

      test('la preferencia se lee en cada intento (se puede apagar)', () async {
        await seedStates();
        var on = true;
        final svc = build(enabledProvider: () async => on, verifier: realLike);
        expect(await svc.verifiedDeleteCandidates(), isNotEmpty);
        on = false;
        expect(await svc.verifiedDeleteCandidates(), isEmpty);
        final all = await repo.getItemsByFolder(null);
        expect(
          await svc.deleteOriginalsConfirmedInCloud(
            candidates: all,
            userConfirmed: true,
          ),
          isEmpty,
        );
        expect(source.deleted, isEmpty);
      });

      test(
        'si el verificador falla en el último momento no se borra',
        () async {
          await seedStates();
          var calls = 0;
          final svc = build(
            enabledProvider: () async => true,
            verifier: (i) async => ++calls == 1, // lista OK, re-verificación no
          );
          final listed = await svc.verifiedDeleteCandidates();
          expect(listed, hasLength(1));
          expect(
            await svc.deleteOriginalsConfirmedInCloud(
              candidates: listed,
              userConfirmed: true,
            ),
            isEmpty,
          );
          expect(source.deleted, isEmpty);
        },
      );
    },
  );

  group('EncryptedThumbnailLoader', () {
    test('descifra, cachea con LRU y falla a null sin llave/archivo', () async {
      final assets = [
        for (var i = 0; i < 3; i++)
          source.add('t$i', GalleryAssetType.image, 50),
      ];
      final res = await build().importAssets(assets, const ImportOptions());
      final items = [
        for (final r in res.items) (await repo.getItem(r.itemId!))!,
      ];
      SecretKey? key = keys.thumbs;
      final loader = EncryptedThumbnailLoader(
        thumbsKey: () => key,
        capacity: 2,
      );
      final b0 = await loader.load(items[0]);
      expect(b0, [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
      await loader.load(items[1]);
      await loader.load(items[0]); // 0 pasa a más reciente
      await loader.load(items[2]); // expulsa a 1
      expect(loader.cachedCount, 2);
      // 1 fue expulsado: al borrar su archivo ya no se puede recargar.
      AppPaths.resolve(items[1].thumbPath!).deleteSync();
      expect(await loader.load(items[1]), isNull);
      // 0 sigue en caché aunque se borre el archivo.
      AppPaths.resolve(items[0].thumbPath!).deleteSync();
      expect(await loader.load(items[0]), isNotNull);
      expect(await loader.call(items[0]), isNotNull);

      loader.clear();
      key = null;
      expect(await loader.load(items[2]), isNull); // bloqueada
      key = keys.files; // llave equivocada
      expect(await loader.load(items[2]), isNull);
    });
  });
}
