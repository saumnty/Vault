// Arnés de cruce de sesiones (fase 8, DISENO_SENUELO §11.1 y §11.2-7).
//
// Para una operación larga: se cuenta en una pasada en seco cuántos puntos
// de espera (`await`) atraviesa por los fakes con [Gate]; después, para cada
// punto k, se repite en un entorno nuevo, se PAUSA en el punto k, se bloquea,
// se abre la OTRA bóveda, se reanuda y se comprueba que la otra bóveda no
// cambió (ni un archivo ni una fila) y que todo archivo de la bóveda de la
// operación abre con SUS llaves (nada se cifró con las de la otra).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart' show TestFailure;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/photo_saver.dart';
import 'package:vault/data/gallery/video_thumbnailer.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/picker/document_picker.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/trash/trash_repository.dart';

import '../../support/fake_cloud.dart';
import '../../support/fakes.dart';

/// Punto de pausa compartido por todos los fakes de un entorno.
class Gate {
  int hits = 0;
  int? pauseAt;
  final Completer<void> reached = Completer<void>();
  final Completer<void> release = Completer<void>();
  final List<String> trace = [];

  Future<void> hit(String where) async {
    final i = hits++;
    trace.add(where);
    if (i == pauseAt) {
      reached.complete();
      await release.future;
    }
  }
}

VaultSlot otherSlot(VaultSlot s) =>
    s == VaultSlot.primary ? VaultSlot.secondary : VaultSlot.primary;

/// Dos bóvedas reales (sqlite ffi, archivos cifrados) en un directorio
/// temporal, una sola sesión, y un [Gate] en cada acceso a la BD y en los
/// fakes.
class CrossEnv {
  CrossEnv._();

  late Directory base;
  late VaultSession session;
  final store = InMemorySecureStore();
  final gate = Gate();
  final crypto0 = CryptoService();
  final Map<VaultSlot, Uint8List> _dek = {
    VaultSlot.primary: Uint8List.fromList(List.generate(32, (i) => i + 11)),
    VaultSlot.secondary: Uint8List.fromList(List.generate(32, (i) => 200 - i)),
  };
  final Map<VaultSlot, KeyHierarchy> refKeys = {};
  late final Map<VaultSlot, VaultDatabase> _db;
  final cloud = GatedCloud();

  /// Items sembrados por bóveda.
  final Map<VaultSlot, List<VaultItemModel>> seeded = {};

  static Future<CrossEnv> create() async {
    sqfliteFfiInit();
    final e = CrossEnv._();
    e.base = await Directory.systemTemp.createTemp('cross');
    await AppPaths.init(baseDir: e.base);
    VaultPaths.secondary.ensureDirs();
    e.session = VaultSession.create();
    e.cloud.gate = e.gate;
    Future<Database> opener(
      String path, {
      String? password,
      required OpenDatabaseOptions options,
    }) => databaseFactoryFfi.openDatabase(path, options: options);
    e._db = {
      for (final s in VaultSlot.values)
        s: VaultDatabase.forTesting(
          session: e.session,
          opener: opener,
          markerStore: e.store,
          slot: s,
        ),
    };
    for (final s in VaultSlot.values) {
      e.refKeys[s] = await KeyHierarchy.fromDek(e._dek[s]!);
      await e.open(s);
      await e._seed(s);
      e.session.clear();
    }
    return e;
  }

  Future<void> dispose() async {
    session.clear();
    for (final d in _db.values) {
      await d.close();
    }
    AppPaths.resetForTesting();
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> open(VaultSlot s) async =>
      session.open(await KeyHierarchy.fromDek(_dek[s]!), slot: s);

  VaultPaths paths(VaultSlot s) => VaultPaths.of(s);

  /// Repositorio de [s] con un punto de pausa en CADA acceso a la BD.
  VaultDataRepository repo(VaultSlot s) => VaultDataRepository(
    dbProvider: () async {
      await gate.hit('db');
      return _db[s]!.database;
    },
  );

  TrashRepository trashRepo(VaultSlot s) => TrashRepository(
    dbProvider: () async {
      await gate.hit('db');
      return _db[s]!.database;
    },
  );

  /// Sin pausas (sembrar y comprobar).
  VaultDataRepository rawRepo(VaultSlot s) =>
      VaultDataRepository(dbProvider: () => _db[s]!.database);

  SessionTicket? Function() ticketFor(VaultSlot s) =>
      () => session.isUnlockedAs(s) ? session.ticket() : null;

  Future<void> _seed(VaultSlot s) async {
    final keys = refKeys[s]!;
    final repo = rawRepo(s);
    final list = <VaultItemModel>[];
    for (var n = 0; n < 4; n++) {
      final id = const Uuid().v4();
      final plain = utf8.encode('contenido $s $n ' * 50);
      final enc = await crypto0.encryptBytes(plain, keys.files);
      final rel = AppPaths.vaultRelativePath(id);
      final thumbRel = AppPaths.thumbRelativePath(id);
      final tEnc = await crypto0.encryptBytes(
        utf8.encode('mini $n'),
        keys.thumbs,
      );
      // n=0: local + miniatura; n=1: en la nube verificado y local (caché);
      // n=2: en la nube, SIN copia local (descarga); n=3: sin miniatura en
      // disco (regeneración).
      String? driveId;
      String? md5;
      if (n == 1 || n == 2) {
        final up = await cloud.uploadBytes(bytes: enc, name: '$id.vault');
        driveId = up.id;
        md5 = crypto.md5.convert(enc).toString();
      }
      if (n != 2) await paths(s).resolve(rel).writeAsBytes(enc, flush: true);
      if (n != 3) {
        await paths(s).resolve(thumbRel).writeAsBytes(tEnc, flush: true);
      }
      final item = VaultItemModel(
        keyGen: 1,
        id: id,
        name: 'f$n.jpg',
        encryptedPath: rel,
        fileSize: plain.length,
        mimeType: 'image/jpeg',
        createdAt: '2026-01-0${n + 1}T00:00:00',
        syncStatus: driveId == null ? SyncStatus.pendiente : SyncStatus.enNube,
        driveFileId: driveId,
        cloudMd5: md5,
        cloudSize: driveId == null ? null : enc.length,
        thumbPath: thumbRel,
        fileId: CryptoService.fileIdOfHeader(enc),
        thumbFileId: CryptoService.fileIdOfHeader(tEnc),
        sourceAssetId: 'asset$n',
      );
      await repo.insertItem(item);
      list.add(item);
    }
    await TrashRepository(
      dbProvider: () => _db[s]!.database,
    ).trashItem(list[0].id, now: 1);
    seeded[s] = list;
  }

  /// Huella de los archivos de [s] (sin la BD ni la caché).
  Map<String, String> files(VaultSlot s) {
    final root = paths(s).root;
    final out = <String, String>{};
    for (final d in [paths(s).vaultDir, paths(s).thumbsDir]) {
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        final rel = p.relative(f.path, from: root.path).replaceAll('\\', '/');
        out[rel] = crypto.sha256.convert(f.readAsBytesSync()).toString();
      }
    }
    return out;
  }

  /// Filas de [s] (abre [s] y deja la sesión BLOQUEADA).
  Future<String> rows(VaultSlot s) async {
    session.clear();
    await open(s);
    final db = await _db[s]!.database;
    final buf = StringBuffer();
    for (final t in ['vault_items', 'folders', 'tags', 'item_tags']) {
      final r = await db.query(t, orderBy: 'rowid');
      buf.writeln('$t ${jsonEncode(r)}');
    }
    session.clear();
    return buf.toString();
  }

  /// Todo `.vault`/`.thumb` de [s] abre con las llaves de [s] (y ninguno con
  /// las de la otra bóveda).
  Future<void> expectOwnKeysOnly(VaultSlot s) async {
    final own = refKeys[s]!;
    final other = refKeys[otherSlot(s)]!;
    for (final rel in files(s).keys) {
      final f = paths(s).root.path;
      final bytes = File(p.join(f, rel)).readAsBytesSync();
      final isThumb = rel.endsWith('.thumb');
      final key = isThumb ? own.thumbs : own.files;
      final otherKey = isThumb ? other.thumbs : other.files;
      await crypto0.decryptBytes(bytes, key); // lanza si no
      var opened = false;
      try {
        await crypto0.decryptBytes(bytes, otherKey);
        opened = true;
      } on Object {
        // bien
      }
      if (opened) throw StateError('$rel abre con las llaves de la otra');
    }
  }
}

/// Nube falsa con pausa en las descargas.
class GatedCloud extends FakeCloudStorage {
  GatedCloud() : super(email: 'dueno@example.com');
  Gate? gate;

  @override
  Future<void> download(
    String fileId,
    File destination, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
    int? maxBytes,
  }) async {
    await gate?.hit('cloud.download');
    return super.download(
      fileId,
      destination,
      onProgress: onProgress,
      cancel: cancel,
      maxBytes: maxBytes,
    );
  }
}

/// Galería falsa con pausas en el original y en la miniatura.
class GatedSource implements GalleryAssetSource {
  GatedSource(this.gate, this.dir);
  final Gate gate;
  final Directory dir;

  GalleryAsset asset(String id) => GalleryAsset(
    id: id,
    type: GalleryAssetType.image,
    title: '$id.jpg',
    duration: Duration.zero,
  );

  @override
  Future<GalleryPermission> requestPermission() async =>
      GalleryPermission.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<int> assetCount() async => 0;
  @override
  Future<List<GalleryAsset>> listAssets({
    required int page,
    required int size,
  }) async => const [];
  @override
  Future<bool> isLocallyAvailable(String id) async {
    await gate.hit('source.local');
    return true;
  }

  @override
  Future<OriginFile?> originFile(
    String id, {
    bool allowNetwork = false,
    void Function(double)? onProgress,
  }) async {
    await gate.hit('source.origin');
    final f = File(p.join(dir.path, 'o_$id'))
      ..writeAsBytesSync(utf8.encode('original $id ' * 40));
    return OriginFile(f, isTemporary: true);
  }

  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async {
    await gate.hit('source.thumb');
    return Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
  }

  @override
  Future<void> clearPlainCaches() async {}
  @override
  Future<List<String>> deleteAssets(List<String> ids) async => const [];
}

class NoVideoThumbs implements VideoThumbnailer {
  @override
  Future<Uint8List?> thumbnail(File video, {int size = 256}) async => null;
}

/// Selector falso con pausas al elegir y en cada lectura.
class GatedPicker implements DocumentPicker {
  GatedPicker(this.gate);
  final Gate gate;

  @override
  Future<PickedDocument?> pick() async {
    await gate.hit('picker.pick');
    return _Doc(gate, Uint8List.fromList(utf8.encode('documento ' * 300)));
  }
}

class _Doc implements PickedDocument {
  _Doc(this.gate, this.bytes);
  final Gate gate;
  final Uint8List bytes;
  int _off = 0;

  @override
  String get name => 'doc.pdf';
  @override
  int? get size => bytes.length;
  @override
  String? get extension => 'pdf';
  @override
  Future<Uint8List> read(int length) async {
    await gate.hit('picker.read');
    final end = (_off + length).clamp(0, bytes.length);
    final out = Uint8List.sublistView(bytes, _off, end);
    _off = end;
    return Uint8List.fromList(out);
  }

  @override
  Future<void> close() async {}
}

/// Fotos falsa con pausas; registra lo que se guardó.
class GatedSaver implements PhotoSaver {
  GatedSaver(this.gate);
  final Gate gate;
  final List<String> saved = [];

  @override
  Future<bool> requestAddPermission() async {
    await gate.hit('saver.permission');
    return true;
  }

  @override
  Future<void> openSettings() async {}
  @override
  Future<void> saveImage(File file, {required String filename}) async {
    saved.add(filename);
  }

  @override
  Future<void> saveVideo(File file, {required String filename}) async {
    saved.add(filename);
  }
}

/// Resultado de una corrida pausada en el punto [k].
class CrossRun {
  CrossRun(this.k, this.where, this.error);
  final int k;
  final String where;
  final Object? error;
}

/// Ejecuta [op] (en la bóveda [slot]) pausándola en cada punto de espera,
/// cruzando a la otra bóveda y comprobando las invariantes. [check] recibe
/// el entorno tras cada corrida para comprobaciones propias de la operación.
Future<List<CrossRun>> runCrossing({
  required VaultSlot slot,
  required Future<Object?> Function(CrossEnv e) op,
  Future<void> Function(CrossEnv e, CrossRun run)? check,
  bool skipOwnKeysCheck = false,
}) async {
  // Pasada en seco: cuántos puntos hay.
  final dry = await CrossEnv.create();
  int points;
  try {
    await dry.open(slot);
    await op(dry);
    points = dry.gate.hits;
  } finally {
    await dry.dispose();
  }
  if (points == 0) throw StateError('la operación no atraviesa ningún punto');
  final runs = <CrossRun>[];
  for (var k = 0; k < points; k++) {
    final e = await CrossEnv.create();
    try {
      final other = otherSlot(slot);
      final otherFiles = e.files(other);
      final otherRows = await e.rows(other);
      await e.open(slot);
      e.gate.pauseAt = k;
      Object? error;
      final running = op(
        e,
      ).then<Object?>((v) => null, onError: (Object err) => err);
      await Future.any([e.gate.reached.future, running]);
      final where = e.gate.reached.isCompleted ? e.gate.trace[k] : '(fin)';
      // Cruce: bloquear y abrir la OTRA bóveda; reanudar.
      e.session.clear();
      await e.open(other);
      if (!e.gate.release.isCompleted) e.gate.release.complete();
      error = await running;
      // Un `expect` que falla dentro de la operación es un fallo del test.
      if (error is TestFailure) throw error;
      final run = CrossRun(k, where, error);
      runs.add(run);
      // La otra bóveda no cambió.
      final nowFiles = e.files(other);
      if (!_sameMap(nowFiles, otherFiles)) {
        throw StateError('k=$k ($where): cambiaron archivos de $other');
      }
      final nowRows = await e.rows(other);
      if (nowRows != otherRows) {
        throw StateError('k=$k ($where): cambiaron filas de $other');
      }
      // Nada cifrado con llaves cruzadas, en ninguna de las dos.
      if (!skipOwnKeysCheck) await e.expectOwnKeysOnly(slot);
      await e.expectOwnKeysOnly(other);
      await check?.call(e, run);
    } finally {
      await e.dispose();
    }
  }
  return runs;
}

bool _sameMap(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
