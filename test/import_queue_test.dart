// v2.2 (D86–D88): cola de importación persistente y reanudable. Con fakes de
// la galería y del compresor, BD sqlite real (esquema v12) y cifrado real.
// Los «cierres» de la app se simulan congelando el servicio en un punto del
// ciclo de un archivo (un Future que nunca termina) y creando servicios
// NUEVOS sobre la misma BD y los mismos archivos, como al reabrir.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/session_ticket.dart';
import 'package:vault/core/session/vault_slot.dart';
import 'package:vault/data/gallery/gallery_album_source.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/data/gallery/import_queue_repository.dart';
import 'package:vault/data/gallery/import_queue_service.dart';
import 'package:vault/data/gallery/import_wake_lock.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/data/gallery/video_thumbnailer.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/network_monitor.dart';

import 'support/fake_cloud.dart' show FakeNetworkMonitor;

// ---------------------------------------------------------------- fakes

/// Un punto de congelación: `hit` se completa al llegar y el código queda
/// esperando a `release` (que en un «cierre» nunca llega).
class Freeze {
  final Completer<void> hit = Completer<void>();
  final Completer<void> release = Completer<void>();

  Future<void> wait() {
    if (!hit.isCompleted) hit.complete();
    return release.future;
  }
}

class FakeAlbumSource implements GalleryAlbumSource {
  FakeAlbumSource(this.dir);
  final Directory dir;

  /// albumId -> ids en orden.
  final Map<String, List<String>> albums = {};
  final Map<String, GalleryAsset> meta = {};
  final Map<String, Uint8List> contents = {};
  final Set<String> gone = {};
  final Set<String> throwOn = {};
  final Set<String> noSpaceOn = {};
  final Set<String> remoteOnly = {};
  final List<(int, int)> albumPageCalls = [];
  final List<String> byIdCalls = [];
  final List<List<String>> deleteCalls = [];
  bool rejectDelete = false;
  int concurrent = 0;
  int maxConcurrent = 0;

  /// Hooks por asset (congelar, bloquear, pausar…).
  Future<void> Function(String id)? beforeOrigin;
  Future<void> Function(String id)? beforeThumb;

  GalleryAsset add(
    String id, {
    String album = 'al',
    bool video = false,
    int size = 400,
    int seed = 0,
  }) {
    contents[id] = Uint8List.fromList(
      List.generate(size, (i) => (i * 13 + id.hashCode + seed) % 251),
    );
    final a = GalleryAsset(
      id: id,
      type: video ? GalleryAssetType.video : GalleryAssetType.image,
      title: video ? '$id.mp4' : '$id.jpg',
      duration: Duration(seconds: video ? 10 : 0),
      width: 1000,
      height: 1000,
    );
    meta[id] = a;
    (albums[album] ??= []).add(id);
    return a;
  }

  @override
  Future<List<GalleryAlbum>> listAlbums() async => [
    for (final e in albums.entries)
      GalleryAlbum(id: e.key, name: 'Álbum ${e.key}', count: e.value.length),
  ];

  @override
  Future<List<GalleryAsset>> listAlbumAssets(
    String albumId, {
    required int page,
    required int size,
  }) async {
    albumPageCalls.add((page, size));
    final ids = albums[albumId] ?? const [];
    final start = page * size;
    if (start >= ids.length) return const [];
    final end = start + size > ids.length ? ids.length : start + size;
    return [for (final id in ids.sublist(start, end)) meta[id]!];
  }

  @override
  Future<GalleryAsset?> assetById(String id) async {
    byIdCalls.add(id);
    if (gone.contains(id)) return null;
    return meta[id];
  }

  @override
  Future<GalleryPermission> requestPermission() async =>
      GalleryPermission.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<int> assetCount() async => meta.length;
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
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      await beforeOrigin?.call(id);
      if (throwOn.contains(id)) throw const FileSystemException('lectura');
      if (noSpaceOn.contains(id)) {
        throw const FileSystemException('lleno', null, OSError('ENOSPC', 28));
      }
      if (gone.contains(id)) return null;
      onProgress?.call(0.5);
      final f = File('${dir.path}/origin_$id.bin')
        ..writeAsBytesSync(contents[id]!);
      return OriginFile(f, isTemporary: true);
    } finally {
      concurrent--;
    }
  }

  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async {
    await beforeThumb?.call(id);
    return Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
  }

  /// Como el plugin: borra sus copias temporales.
  @override
  Future<void> clearPlainCaches() async {
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.contains('origin_')) f.deleteSync();
    }
  }

  @override
  Future<List<String>> deleteAssets(List<String> ids) async {
    deleteCalls.add(List.of(ids));
    return rejectDelete ? const [] : ids;
  }
}

class FakeCompressor implements VideoCompressor {
  Directory? outDir;
  Future<void> Function()? hook;
  int cleanups = 0;

  @override
  Future<CompressedVideo?> compress(
    File source,
    VideoQualityOption quality, {
    void Function(double)? onProgress,
  }) async {
    await hook?.call();
    final bytes = source.readAsBytesSync();
    // No determinista, como un codificador real: depende de la hora.
    final out =
        File(
            '${outDir!.path}/c_${DateTime.now().microsecondsSinceEpoch}.bin',
          )
          ..writeAsBytesSync([
            ...bytes.sublist(0, bytes.length ~/ 2),
            DateTime.now().microsecond % 251,
          ]);
    return CompressedVideo(out, out.lengthSync());
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> cleanup() async => cleanups++;
}

class NoVideoThumbs implements VideoThumbnailer {
  @override
  Future<Uint8List?> thumbnail(File video, {int size = 256}) async => null;
}

class CountingWakeLock implements ImportWakeLock {
  int on = 0;
  int off = 0;
  bool get active => on > off;
  @override
  Future<void> enable() async => on++;
  @override
  Future<void> disable() async => off++;
}

class TestTicket implements SessionTicket {
  TestTicket(this.epoch);
  bool valid = true;
  @override
  final int epoch;
  @override
  VaultSlot get slot => VaultSlot.primary;
  @override
  bool get isValid => valid;
  @override
  void check() {
    if (!valid) throw SessionChangedException();
  }
}

/// Repositorio que puede congelarse JUSTO después de escribir la fila.
class HookedRepo extends VaultDataRepository {
  HookedRepo(Future<Database> Function() db) : super(dbProvider: db);
  Future<void> Function(VaultItemModel item)? afterInsert;

  @override
  Future<void> insertItem(VaultItemModel item) async {
    await super.insertItem(item);
    await afterInsert?.call(item);
  }
}

// ---------------------------------------------------------------- entorno

class Env {
  late Directory tmp;
  late Directory scratch;
  late Database db;
  late KeyHierarchy keys;
  late FakeAlbumSource source;
  late FakeCompressor compressor;
  final net = FakeNetworkMonitor();
  final wake = CountingWakeLock();
  int? free = 50 * 1024 * 1024 * 1024;
  TestTicket? ticket;
  int epoch = 0;
  int ids = 0;

  /// Servicios «del proceso actual» (se recrean al simular un cierre).
  late HookedRepo repo;
  late GalleryImportService importer;
  late ImportQueueService queue;
  late ImportQueueRepository queueRepo;

  Future<void> setUp() async {
    sqfliteFfiInit();
    tmp = await Directory.systemTemp.createTemp('import_queue');
    scratch = Directory('${tmp.path}/src')..createSync();
    await AppPaths.init(baseDir: Directory('${tmp.path}/app'));
    db = await databaseFactoryFfi.openDatabase(
      '${tmp.path}/db.sqlite',
      options: OpenDatabaseOptions(
        version: VaultSchema.version,
        onCreate: (d, v) => VaultSchema.create(d),
      ),
    );
    keys = await KeyHierarchy.fromDek(
      Uint8List.fromList(List.generate(32, (i) => i + 9)),
    );
    source = FakeAlbumSource(scratch);
    compressor = FakeCompressor()..outDir = scratch;
    unlock();
    restart();
  }

  Future<void> tearDown() async {
    await db.close();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  void lock() {
    ticket?.valid = false;
    ticket = null;
    queue.onLock();
    importer.cancelRunning();
  }

  void unlock() => ticket = TestTicket(++epoch);

  /// «Reabrir la app»: servicios nuevos sobre la misma BD y archivos.
  void restart({int pageSize = 50}) {
    repo = HookedRepo(() async => db);
    queueRepo = ImportQueueRepository(dbProvider: () async => db);
    importer = GalleryImportService(
      source: source,
      compressor: compressor,
      repository: repo,
      filesKey: () => ticket == null ? null : keys.files,
      thumbsKey: () => ticket == null ? null : keys.thumbs,
      tempDirProvider: () => Directory('${tmp.path}/import_tmp'),
      videoThumbnailer: NoVideoThumbs(),
      sessionTicket: () => ticket,
      isIOS: false,
    );
    queue = ImportQueueService(
      importer: importer,
      source: source,
      queue: queueRepo,
      freeSpace: () async => free,
      network: net,
      wakeLock: wake,
      sessionTicket: () => ticket,
      isIOS: false,
      pageSize: pageSize,
      idGenerator: () {
        ids++;
        final h = ids.toRadixString(16).padLeft(12, '0');
        return '00000000-0000-4000-8000-$h';
      },
    );
  }

  Future<ImportPreflight> prepareAlbum({
    String album = 'al',
    Set<String> excluded = const {},
    VideoQualityOption quality = VideoQualityOption.original,
  }) => queue.prepare(
    ImportRequest.album(album, excluded: excluded, videoQuality: quality),
  );

  Future<List<VaultItemModel>> liveItems() async =>
      (await db.query('vault_items', where: 'deletedAt IS NULL'))
          .map(VaultItemModel.fromMap)
          .toList();

  /// Archivos cifrados en disco sin fila en la BD.
  Future<List<String>> orphans() async {
    final rows = {
      for (final r in await db.query('vault_items', columns: ['id']))
        r['id'] as String,
    };
    final out = <String>[];
    for (final sub in ['vault', 'thumbs']) {
      final d = Directory('${tmp.path}/app/$sub');
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final id = name.split('.').first;
        if (!rows.contains(id)) out.add('$sub/$name');
      }
    }
    return out;
  }

  /// Restos en claro: copias del original y carpeta de trabajo.
  List<String> plainLeftovers() => [
    for (final f in scratch.listSync().whereType<File>())
      if (f.path.contains('origin_') || f.path.contains('c_')) f.path,
    if (Directory('${tmp.path}/import_tmp').existsSync())
      for (final f
          in Directory('${tmp.path}/import_tmp')
              .listSync(recursive: true)
              .whereType<File>())
        f.path,
  ];

  Future<ImportCounts> counts() async =>
      queueRepo.counts((await queueRepo.currentBatch())!.id);
}

Future<String> sha(Uint8List b) async => (await Sha256().hash(
  b,
)).bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Env e;

  setUp(() async {
    e = Env();
    await e.setUp();
  });
  tearDown(() async => e.tearDown());

  Future<void> runAlbum({
    VideoQualityOption quality = VideoQualityOption.original,
  }) async {
    final pre = await e.prepareAlbum(quality: quality);
    await e.queue.start(pre.batchId);
  }

  group('cola persistente', () {
    test('importa el álbum entero, de uno en uno, y lo deja en la BD', () async {
      for (var i = 0; i < 12; i++) {
        e.source.add('a$i');
      }
      final pre = await e.prepareAlbum();
      expect(pre.total, 12);
      expect(pre.estimatedBytes, greaterThan(0));
      expect(e.source.byIdCalls, isEmpty, reason: 'preparar no pide assets');
      await e.queue.start(pre.batchId);
      final c = await e.counts();
      expect(c.done, 12);
      expect(c.remaining, 0);
      expect(e.queue.status.value.state, ImportBatchState.finished);
      final items = await e.liveItems();
      expect(items.map((i) => i.sourceAssetId).toSet().length, 12);
      for (final it in items) {
        expect(it.contentHash, await sha(e.source.contents[it.sourceAssetId]!));
        expect(it.sourceHash, it.contentHash);
      }
      expect(e.source.maxConcurrent, 1);
      expect(await e.orphans(), isEmpty);
      expect(e.plainLeftovers(), isEmpty);
      // Pantalla encendida solo durante el lote, liberada al final.
      expect(e.wake.on, 1);
      expect(e.wake.off, 1);
      // «Listo»: el lote desaparece.
      await e.queue.acknowledge();
      expect(await e.queueRepo.currentBatch(), isNull);
    });

    test('excluidos y carpeta destino', () async {
      for (var i = 0; i < 5; i++) {
        e.source.add('a$i');
      }
      await e.db.insert('folders', {
        'id': 'f',
        'name': 'Álbum al',
        'createdAt': 'x',
      });
      final pre = await e.prepareAlbum(excluded: {'a1', 'a3'});
      expect(pre.total, 3);
      await e.queue.start(pre.batchId, folderId: 'f');
      final items = await e.liveItems();
      expect(items.map((i) => i.sourceAssetId).toSet(), {'a0', 'a2', 'a4'});
      expect(items.every((i) => i.folderId == 'f'), isTrue);
    });

    test('la carpeta destino va a la Papelera a mitad: el resto va a la raíz', () async {
      for (var i = 0; i < 3; i++) {
        e.source.add('a$i');
      }
      await e.db.insert('folders', {'id': 'f', 'name': 'F', 'createdAt': 'x'});
      e.source.beforeOrigin = (id) async {
        if (id == 'a1') {
          await e.db.update('folders', {'deletedAt': 1, 'trashRoot': 'f'});
        }
      };
      final pre = await e.prepareAlbum();
      await e.queue.start(pre.batchId, folderId: 'f');
      final byAsset = {
        for (final i in await e.liveItems()) i.sourceAssetId: i.folderId,
      };
      expect(byAsset['a0'], 'f');
      expect(byAsset['a2'], isNull);
    });

    test('un lote abierto impide preparar otro; uno terminado se reemplaza', () async {
      e.source.add('a0');
      final freeze = Freeze();
      e.source.beforeOrigin = (_) => freeze.wait();
      final pre = await e.prepareAlbum();
      unawaited(e.queue.start(pre.batchId));
      await freeze.hit.future;
      await expectLater(
        e.queue.prepare(const ImportRequest.album('al')),
        throwsA(isA<ImportBatchBusyException>()),
      );
      e.source.beforeOrigin = null;
      freeze.release.complete();
      while (e.queue.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final again = await e.prepareAlbum();
      expect(again.total, 1);
      expect(again.batchId, isNot(pre.batchId));
    });

    test('preparar y no confirmar: se descarta (también tras un cierre)', () async {
      e.source.add('a0');
      final pre = await e.prepareAlbum();
      await e.queue.discard(pre.batchId);
      expect(await e.db.query('import_queue'), isEmpty);
      // Cierre con un lote `preparing`: al desbloquear se descarta.
      await e.prepareAlbum();
      e.restart();
      expect(await e.queue.onUnlocked(), isNull);
      expect(await e.db.query('import_batches'), isEmpty);
      expect(await e.db.query('import_queue'), isEmpty);
    });

    test('lista explícita (selección): solo esos, en orden', () async {
      final a = e.source.add('x1');
      final b = e.source.add('x2');
      e.source.add('x3');
      final pre = await e.queue.prepare(ImportRequest.assets([b, a]));
      expect(pre.total, 2);
      await e.queue.start(pre.batchId);
      final rows = await e.db.query('import_queue', orderBy: 'seq');
      expect(rows.map((r) => r['assetId']), ['x2', 'x1']);
      expect((await e.liveItems()).length, 2);
    });
  });

  group('memoria acotada', () {
    test('1000 elementos: se paginan de 50 en 50 y solo se guardan ids', () async {
      for (var i = 0; i < 1000; i++) {
        e.source.add('m$i', size: 10);
      }
      final pre = await e.prepareAlbum();
      expect(pre.total, 1000);
      // Nunca una página mayor que pageSize, y en orden.
      expect(e.source.albumPageCalls.every((c) => c.$2 == 50), isTrue);
      expect(
        e.source.albumPageCalls.map((c) => c.$1).toList(),
        List.generate(e.source.albumPageCalls.length, (i) => i),
      );
      expect(e.source.albumPageCalls.length, inInclusiveRange(20, 21));
      expect(e.source.byIdCalls, isEmpty);
      // La cola solo tiene ids y estado.
      final row = (await e.db.query('import_queue', limit: 1)).single;
      expect(row['assetId'], 'm0');
      expect(row['name'], isNull);
      await e.queue.discard(pre.batchId);
    });

    test('al importar se lee una fila y un asset cada vez', () async {
      for (var i = 0; i < 200; i++) {
        e.source.add('m$i', size: 16);
      }
      await runAlbum();
      expect((await e.counts()).done, 200);
      expect(e.source.byIdCalls.length, 200);
      expect(e.source.maxConcurrent, 1);
    });
  });

  group('dedupe', () {
    test('mismo asset y mismo contenido: «ya estaba»; editado: se importa', () async {
      e.source.add('d1');
      e.source.add('d2');
      await runAlbum();
      await e.queue.acknowledge();
      expect((await e.liveItems()).length, 2);
      // d2 se editó en la galería (mismo id, otro contenido).
      e.source.contents['d2'] = Uint8List.fromList([1, 2, 3, 4]);
      await runAlbum();
      final c = await e.counts();
      expect(c.duplicate, 1);
      expect(c.done, 1);
      expect((await e.liveItems()).length, 3);
    });

    test('video comprimido: el original se reconoce por sourceHash', () async {
      e.source.add('v1', video: true, size: 3000);
      await runAlbum(quality: VideoQualityOption.p720);
      await e.queue.acknowledge();
      final first = (await e.liveItems()).single;
      expect(first.sourceHash, await sha(e.source.contents['v1']!));
      expect(first.contentHash, isNot(first.sourceHash));
      await runAlbum(quality: VideoQualityOption.p720);
      expect((await e.counts()).duplicate, 1);
      expect((await e.liveItems()).length, 1);
    });

    test('filas anteriores a v12 (sin sourceHash) también cuentan', () async {
      e.source.add('o1');
      await e.db.insert('vault_items', {
        'id': 'old',
        'name': 'o1.jpg',
        'encryptedPath': 'vault/old.vault',
        'fileSize': 1,
        'createdAt': 'x',
        'sourceAssetId': 'o1',
        'contentHash': await sha(e.source.contents['o1']!),
      });
      await runAlbum();
      expect((await e.counts()).duplicate, 1);
    });

    test('lo que está en la Papelera NO cuenta: se importa de nuevo', () async {
      e.source.add('t1');
      await runAlbum();
      await e.queue.acknowledge();
      await e.db.update('vault_items', {'deletedAt': 5, 'trashRoot': 'x'});
      await runAlbum();
      expect((await e.counts()).done, 1);
      expect((await e.liveItems()).length, 1);
    });
  });

  group('errores por archivo', () {
    test('un archivo que falla no detiene el lote; motivo guardado', () async {
      for (var i = 0; i < 4; i++) {
        e.source.add('e$i');
      }
      e.source.throwOn.add('e1');
      e.source.gone.add('e2');
      await runAlbum();
      final c = await e.counts();
      expect(c.done, 2);
      expect(c.error, 2);
      final errs = await e.queue.errors();
      expect(errs.map((j) => j.error), [
        ImportErrorCode.read,
        ImportErrorCode.gone,
      ]);
      expect(errs.first.name, 'e1.jpg');
      expect(e.queue.status.value.state, ImportBatchState.finished);
      expect(await e.orphans(), isEmpty);
      expect(e.plainLeftovers(), isEmpty);
    });

    test('sin espacio a mitad: pausa (no 1000 errores); reanuda al liberar', () async {
      for (var i = 0; i < 4; i++) {
        e.source.add('s$i');
      }
      e.source.noSpaceOn.add('s2');
      await runAlbum();
      expect(e.queue.status.value.state, ImportBatchState.paused);
      expect(e.queue.status.value.pauseReason, ImportPauseReason.noSpace);
      var c = await e.counts();
      expect(c.done, 2);
      expect(c.error, 0);
      expect(c.pending, 2);
      expect(e.wake.active, isFalse);
      e.source.noSpaceOn.clear();
      await e.queue.resume();
      c = await e.counts();
      expect(c.done, 4);
      expect(await e.orphans(), isEmpty);
    });

    test('preflight: espacio insuficiente y datos móviles en iOS', () async {
      for (var i = 0; i < 10; i++) {
        e.source.add('p$i');
      }
      e.free = 1024;
      final pre = await e.prepareAlbum();
      expect(pre.spaceInsufficient, isTrue);
      expect(pre.freeBytes, 1024);
      expect(pre.cellular, isFalse);
      await e.queue.discard(pre.batchId);
      // Sin poder saber el espacio: no bloquea.
      e.free = null;
      final p2 = await e.prepareAlbum();
      expect(p2.spaceInsufficient, isFalse);
      await e.queue.discard(p2.batchId);
      // iOS con datos móviles.
      e.net.kind = NetworkKind.mobile;
      final ios = ImportQueueService(
        importer: e.importer,
        source: e.source,
        queue: e.queueRepo,
        network: e.net,
        sessionTicket: () => e.ticket,
        isIOS: true,
      );
      final p3 = await ios.prepare(const ImportRequest.album('al'));
      expect(p3.cellular, isTrue);
    });

    test('estimación: foto por píxeles, video por bitrate y calidad', () {
      int? est(Duration d) => estimateVideoBytes(
        duration: d,
        quality: VideoQualityOption.p720,
      );
      const photo = GalleryAsset(
        id: 'p',
        type: GalleryAssetType.image,
        width: 4000,
        height: 3000,
      );
      expect(
        estimateAssetBytes(photo, compress: false, estimateVideo: est),
        4200000,
      );
      const video = GalleryAsset(
        id: 'v',
        type: GalleryAssetType.video,
        width: 1920,
        height: 1080,
        duration: Duration(seconds: 60),
      );
      final original = estimateAssetBytes(
        video,
        compress: false,
        estimateVideo: est,
      );
      expect(original, 60 * 17000000 ~/ 8);
      expect(
        estimateAssetBytes(video, compress: true, estimateVideo: est),
        est(const Duration(seconds: 60)),
      );
    });
  });

  group('pausar, reanudar, cancelar', () {
    test('pausar a mitad de un archivo: vuelve a la cola y nada queda', () async {
      for (var i = 0; i < 4; i++) {
        e.source.add('q$i');
      }
      final freeze = Freeze();
      e.source.beforeOrigin = (id) async {
        if (id == 'q1') {
          e.queue.pause();
          // el archivo sigue un poco después de la pausa
        }
      };
      final pre = await e.prepareAlbum();
      await e.queue.start(pre.batchId);
      expect(e.queue.status.value.state, ImportBatchState.paused);
      expect(e.queue.status.value.pauseReason, ImportPauseReason.user);
      var c = await e.counts();
      expect(c.done, 1);
      expect(c.pending, 3);
      expect(c.running, 0);
      expect(await e.orphans(), isEmpty);
      expect(e.plainLeftovers(), isEmpty);
      expect(e.wake.active, isFalse);
      e.source.beforeOrigin = null;
      await e.queue.resume();
      c = await e.counts();
      expect(c.done, 4);
      expect((await e.liveItems()).length, 4);
      expect(freeze.hit.isCompleted, isFalse);
    });

    test('cancelar: lo pendiente no se importa; resumen; «Listo» lo borra', () async {
      for (var i = 0; i < 5; i++) {
        e.source.add('c$i');
      }
      e.source.beforeOrigin = (id) async {
        if (id == 'c2') unawaited(e.queue.cancel());
      };
      await runAlbum();
      final st = e.queue.status.value;
      expect(st.state, ImportBatchState.cancelled);
      final c = await e.counts();
      expect(c.done, 2);
      expect(c.pending, 3);
      expect((await e.liveItems()).length, 2);
      expect(await e.orphans(), isEmpty);
      // Un lote cancelado no se reanuda solo.
      e.restart();
      final b = await e.queue.onUnlocked();
      expect(b!.state, ImportBatchState.cancelled);
      expect(e.queue.isRunning, isFalse);
      await e.queue.acknowledge();
      expect(await e.db.query('import_queue'), isEmpty);
    });

    test('cancelar un lote en pausa', () async {
      e.source.add('z0');
      e.source.add('z1');
      e.source.beforeOrigin = (id) async {
        if (id == 'z1') e.queue.pause();
      };
      await runAlbum();
      expect(e.queue.status.value.state, ImportBatchState.paused);
      await e.queue.cancel();
      expect(e.queue.status.value.state, ImportBatchState.cancelled);
    });
  });

  group('bloqueo de la app', () {
    test('bloquear a mitad: se corta limpio, sigue al desbloquear, sin '
        'duplicados ni restos', () async {
      for (var i = 0; i < 5; i++) {
        e.source.add('l$i');
      }
      e.source.beforeThumb = (id) async {
        if (id == 'l2') e.lock();
      };
      await runAlbum();
      // Bloqueada: el lote sigue `running` en la BD; nada a medias.
      expect(e.queue.isRunning, isFalse);
      expect(e.wake.active, isFalse);
      expect(
        (await e.db.query('import_batches')).single['state'],
        'running',
      );
      expect(await e.orphans(), isEmpty);
      expect(e.plainLeftovers(), isEmpty);
      e.source.beforeThumb = null;
      e.unlock();
      final b = await e.queue.onUnlocked();
      expect(b!.state, ImportBatchState.running);
      while (e.queue.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final c = await e.counts();
      expect(c.done, 5);
      expect(c.duplicate, 0);
      expect((await e.liveItems()).length, 5);
      expect(await e.orphans(), isEmpty);
    });

    test('bloquear muchas veces en el MISMO archivo no lo da por perdido', () async {
      e.source.add('big');
      var locks = 0;
      e.source.beforeThumb = (id) async {
        if (locks < 5) {
          locks++;
          e.lock();
        }
      };
      await runAlbum();
      for (var i = 0; i < 5; i++) {
        e.unlock();
        await e.queue.onUnlocked();
        while (e.queue.isRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      final c = await e.counts();
      expect(c.done, 1);
      expect(c.error, 0);
    });
  });

  group('cierre de la app en cada punto del ciclo de un archivo', () {
    // Cada punto congela el servicio (como si iOS matara la app) y luego se
    // «reabre» con servicios nuevos.
    final points = <String, void Function(Env e, Freeze f)>{
      'antes de leer el original': (e, f) => e.source.beforeOrigin = (id) async {
        if (id == 'k2') await f.wait();
      },
      'comprimiendo': (e, f) {
        e.compressor.hook = () async {
          if (!f.hit.isCompleted) await f.wait();
        };
      },
      '.vault escrito, sin fila (miniatura)': (e, f) =>
          e.source.beforeThumb = (id) async {
            if (id == 'k2') await f.wait();
          },
      'fila escrita, cola sin marcar': (e, f) => e.repo.afterInsert = (it) async {
        if (it.sourceAssetId == 'k2') await f.wait();
      },
    };

    for (final entry in points.entries) {
      test(entry.key, () async {
        for (var i = 0; i < 5; i++) {
          e.source.add('k$i', video: entry.key == 'comprimiendo' && i == 2);
        }
        final freeze = Freeze();
        entry.value(e, freeze);
        final quality = entry.key == 'comprimiendo'
            ? VideoQualityOption.p720
            : VideoQualityOption.original;
        final pre = await e.prepareAlbum(quality: quality);
        unawaited(e.queue.start(pre.batchId));
        await freeze.hit.future;
        // «Muere» el proceso: el servicio queda congelado para siempre.
        e.compressor.hook = null;
        e.source.beforeOrigin = null;
        e.source.beforeThumb = null;
        e.unlock(); // nueva sesión tras reabrir
        e.restart();
        final b = await e.queue.onUnlocked();
        expect(b!.state, ImportBatchState.running);
        while (e.queue.isRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final c = await e.counts();
        expect(c.done, 5, reason: entry.key);
        expect(c.duplicate, 0);
        expect(c.error, 0);
        final items = await e.liveItems();
        expect(items.length, 5);
        expect(items.map((i) => i.sourceAssetId).toSet().length, 5);
        expect(await e.orphans(), isEmpty);
        expect(e.plainLeftovers(), isEmpty);
      });
    }

    test('cierre durante la preparación: el lote a medias se descarta', () async {
      for (var i = 0; i < 120; i++) {
        e.source.add('r$i', size: 8);
      }
      // Encolar a mano la primera página, como si se cortara ahí.
      await e.queueRepo.createBatch(
        const ImportBatch(
          id: 'half',
          state: ImportBatchState.preparing,
          videoQuality: VideoQualityOption.original,
        ),
        now: 1,
      );
      await e.queueRepo.addJobs('half', 0, ['r0', 'r1']);
      e.restart();
      expect(await e.queue.onUnlocked(), isNull);
      expect(await e.db.query('import_queue'), isEmpty);
    });

    test('el mismo archivo hace caer la app 3 veces: error y sigue', () async {
      for (var i = 0; i < 3; i++) {
        e.source.add('w$i');
      }
      Future<void> crashOnce() async {
        final f = Freeze();
        e.source.beforeOrigin = (id) async {
          if (id == 'w1') await f.wait();
        };
        e.unlock();
        e.restart();
        final b = await e.queue.onUnlocked();
        if (b == null) {
          final pre = await e.prepareAlbum();
          unawaited(e.queue.start(pre.batchId));
        }
        await f.hit.future;
      }

      for (var i = 0; i < 3; i++) {
        await crashOnce();
      }
      e.source.beforeOrigin = null;
      e.unlock();
      e.restart();
      await e.queue.onUnlocked();
      while (e.queue.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final c = await e.counts();
      expect(c.done, 2);
      expect(c.error, 1);
      expect(
        (await e.queue.errors()).single.error,
        ImportErrorCode.interrupted,
      );
    });
  });

  group('borrado de originales con cientos', () {
    Future<List<VaultItemModel>> seed(int n) async {
      final out = <VaultItemModel>[];
      for (var i = 0; i < n; i++) {
        final m = VaultItemModel(
          keyGen: 1,
          id: 'del$i',
          name: 'f$i.jpg',
          encryptedPath: 'vault/del$i.vault',
          fileSize: 10,
          mimeType: 'image/jpeg',
          createdAt: 'x',
          syncStatus: SyncStatus.enNube,
          driveFileId: 'd$i',
          contentHash: 'h$i',
          sourceAssetId: 'asset$i',
        );
        await e.db.insert('vault_items', m.toMap());
        out.add(m);
      }
      return out;
    }

    GalleryImportService deleter() => GalleryImportService(
      source: e.source,
      compressor: e.compressor,
      repository: e.repo,
      filesKey: () => e.keys.files,
      thumbsKey: () => e.keys.thumbs,
      tempDirProvider: () => Directory('${e.tmp.path}/import_tmp'),
      originalDeletionEnabled: true,
      cloudVerifier: (_) async => true,
      isIOS: false,
    );

    test('1200 originales: trozos de 500 (3 confirmaciones), todos borrados', () async {
      final items = await seed(1200);
      final svc = deleter();
      final progress = <int>[];
      final done = await svc.deleteOriginalsConfirmedInCloud(
        candidates: items,
        userConfirmed: true,
        onProgress: (d, t) => progress.add(d),
      );
      expect(done.length, 1200);
      expect(e.source.deleteCalls.map((c) => c.length), [500, 500, 200]);
      expect(progress.last, 1200);
      // Ninguno vuelve a ser candidato.
      expect(await svc.deleteOriginalCandidates(), isEmpty);
    });

    test('300 originales: UNA sola confirmación', () async {
      final items = await seed(300);
      await deleter().deleteOriginalsConfirmedInCloud(
        candidates: items,
        userConfirmed: true,
      );
      expect(e.source.deleteCalls.length, 1);
      expect(e.source.deleteCalls.single.length, 300);
    });

    test('si el usuario rechaza el primer diálogo no se le vuelve a preguntar', () async {
      final items = await seed(700);
      e.source.rejectDelete = true;
      final done = await deleter().deleteOriginalsConfirmedInCloud(
        candidates: items,
        userConfirmed: true,
      );
      expect(done, isEmpty);
      expect(e.source.deleteCalls.length, 1);
    });
  });
}
