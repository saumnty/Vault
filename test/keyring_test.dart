// D60 (rotación de la DEK, paso 4): llaves por generación en la sesión, BD
// abierta con llaves candidatas y lectores que usan la generación del item.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/thumbnail_regeneration_service.dart';
import 'package:vault/data/gallery/video_thumbnailer.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/features/vault/services/thumbnail_loader.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';

import 'support/f6_env.dart';

Future<KeyHierarchy> _keys(int seed) => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i + seed)),
);

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VaultKeyring', () {
    test('single: una generación', () async {
      final k = await _keys(1);
      final ring = VaultKeyring.single(1, k);
      expect(ring.isDual, isFalse);
      expect(ring.forGen(1), same(k));
      expect(ring.forGenOrNull(2), isNull);
      expect(() => ring.forGen(2), throwsStateError);
      expect(ring.dbCandidates.map((c) => c.$1), [1]);
    });

    test('dual: la anterior primero para la BD', () async {
      final old = await _keys(1);
      final neu = await _keys(2);
      final ring = VaultKeyring.dual(
        currentGen: 2,
        current: neu,
        previousGen: 1,
        previous: old,
      );
      expect(ring.forGen(1), same(old));
      expect(ring.forGen(2), same(neu));
      expect(ring.dbCandidates.map((c) => c.$1), [1, 2]);
      ring.destroy();
      expect(old.isDestroyed && neu.isDestroyed, isTrue);
    });

    test('dual rechaza misma generación o misma DEK', () async {
      final a = await _keys(1);
      final b = await _keys(1);
      final c = await _keys(9);
      expect(
        () => VaultKeyring.dual(
          currentGen: 2,
          current: c,
          previousGen: 2,
          previous: a,
        ),
        throwsArgumentError,
      );
      expect(
        () => VaultKeyring.dual(
          currentGen: 2,
          current: a,
          previousGen: 1,
          previous: b,
        ),
        throwsArgumentError,
      );
      expect(() => VaultKeyring.single(0, a), throwsArgumentError);
    });
  });

  group('VaultSession', () {
    test('generación 1 por defecto: API de siempre', () async {
      final s = VaultSession.create();
      expect(s.currentGen, 1);
      expect(s.filesKeyFor(1), isNull);
      final k = await _keys(1);
      s.open(k);
      expect(s.currentGen, 1);
      expect(s.maxGen, 1);
      expect(s.keys, same(k));
      expect(s.filesKey, same(k.files));
      expect(s.filesKeyFor(1), same(k.files));
      expect(s.thumbsKeyFor(1), same(k.thumbs));
      expect(s.filesKeyFor(2), isNull);
      s.clear();
      expect(k.isDestroyed, isTrue);
      expect(s.dbCandidates, isEmpty);
    });

    test('pasar a dos generaciones conserva la jerarquía ya abierta', () async {
      final s = VaultSession.create();
      final old = await _keys(1);
      s.open(old);
      final oldAgain = await _keys(1); // misma DEK derivada otra vez
      final neu = await _keys(2);
      s.openKeyring(
        VaultKeyring.dual(
          currentGen: 2,
          current: neu,
          previousGen: 1,
          previous: oldAgain,
        ),
      );
      expect(s.keyring!.previous, same(old), reason: 'se reutiliza');
      expect(oldAgain.isDestroyed, isTrue, reason: 'el duplicado se destruye');
      expect(old.isDestroyed, isFalse);
      expect(s.currentGen, 2);
      expect(s.maxGen, 2);
      expect(s.keys, same(neu));
      expect(s.filesKey, same(neu.files), reason: 'lo nuevo, con la nueva');
      expect(s.filesKeyFor(1), same(old.files));
      expect(s.dbCandidates.map((c) => c.$1), [1, 2]);

      // Fin de la rotación: queda solo la nueva y la vieja se destruye.
      final neuAgain = await _keys(2);
      s.open(neuAgain, gen: 2);
      expect(s.keys, same(neu));
      expect(neuAgain.isDestroyed, isTrue);
      expect(old.isDestroyed, isTrue);
      expect(s.filesKeyFor(1), isNull);
    });

    test('otra DEK en la misma generación reemplaza y destruye', () async {
      final s = VaultSession.create();
      final a = await _keys(1);
      final b = await _keys(5);
      s.open(a);
      s.open(b);
      expect(s.keys, same(b));
      expect(a.isDestroyed, isTrue);
    });
  });

  group('VaultDatabase con llaves candidatas', () {
    late Directory tmp;
    late String dbPath;
    // SQLCipher simulado: la BD "sabe" con qué llave se creó.
    final keyOf = <String, String>{};

    setUp(() async {
      sqfliteFfiInit();
      tmp = await Directory.systemTemp.createTemp('keyring_db');
      dbPath = p.join(tmp.path, 'db', 'k.db');
      keyOf.clear();
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<Database> fakeCipher(
      String path, {
      String? password,
      required OpenDatabaseOptions options,
    }) async {
      final existed = File(path).existsSync();
      if (existed && keyOf[path] != password) {
        throw Exception('file is not a database');
      }
      final db = await databaseFactoryFfi.openDatabase(path, options: options);
      keyOf[path] = password!;
      return db;
    }

    VaultDatabase newDb(VaultSession s) => VaultDatabase.forTesting(
      session: s,
      dbPath: dbPath,
      opener: fakeCipher,
      useSqlCipher: true,
    );

    test('BD de la gen 1 abre con la anterior durante la rotación', () async {
      final old = await _keys(1);
      final neu = await _keys(2);
      final s = VaultSession.create()..open(old);
      final vdb = newDb(s);
      await vdb.database;
      expect(vdb.openedGen, 1);
      await vdb.close();

      s.openKeyring(
        VaultKeyring.dual(
          currentGen: 2,
          current: neu,
          previousGen: 1,
          previous: await _keys(1),
        ),
      );
      await vdb.database;
      expect(vdb.openedGen, 1);
      expect(keyOf[dbPath], VaultDatabase.passwordFor(old));

      // "Re-cifrada" (paso 7): la llave del archivo pasa a la nueva.
      await vdb.close();
      keyOf[dbPath] = VaultDatabase.passwordFor(neu);
      await vdb.database;
      expect(vdb.openedGen, 2);
      await vdb.close();
    });

    test('una BD NUEVA se crea con la llave actual', () async {
      final s = VaultSession.create()
        ..openKeyring(
          VaultKeyring.dual(
            currentGen: 2,
            current: await _keys(2),
            previousGen: 1,
            previous: await _keys(1),
          ),
        );
      final vdb = newDb(s);
      await vdb.database;
      expect(vdb.openedGen, 2);
      expect(keyOf[dbPath], VaultDatabase.passwordFor(s.keys));
      await vdb.close();
    });

    test('ninguna candidata abre: lanza y no queda abierta', () async {
      final s = VaultSession.create()..open(await _keys(1));
      final vdb = newDb(s);
      await vdb.database;
      await vdb.close();
      s.open(await _keys(7)); // otra DEK
      await expectLater(vdb.database, throwsException);
      expect(vdb.isOpen, isFalse);
      expect(vdb.openedGen, isNull);
    });

    test('bloqueada: StateError', () async {
      final vdb = newDb(VaultSession.create());
      await expectLater(vdb.database, throwsStateError);
    });
  });

  group('lectores en dos generaciones', () {
    late F6Env env;
    late KeyHierarchy k2;

    setUp(() async {
      env = F6Env();
      await env.setUp();
      k2 = await _keys(200);
      env.session.openKeyring(
        VaultKeyring.dual(
          currentGen: 2,
          current: k2,
          previousGen: 1,
          previous: env.session.keys,
        ),
      );
    });
    tearDown(() => env.tearDown());

    /// Item `en_nube` de la generación 2 con `.vault` y `.thumb` reales.
    Future<VaultItemModel> addGen2(String id, Uint8List plain) async {
      final rel = AppPaths.vaultRelativePath(id, gen: 2);
      final file = AppPaths.resolve(rel);
      final src = File('${file.path}.plain')..writeAsBytesSync(plain);
      final h = await env.crypto.encryptFile(src, file, k2.files);
      src.deleteSync();
      final thumbRel = AppPaths.thumbRelativePath(id, gen: 2);
      final thumb = await env.crypto.encryptBytes([7, 7, 7], k2.thumbs);
      AppPaths.resolve(thumbRel).writeAsBytesSync(thumb);
      await env.items.insertItem(
        VaultItemModel(
          keyGen: 2,
          id: id,
          name: 'foto.jpg',
          encryptedPath: rel,
          fileSize: plain.length,
          mimeType: 'image/jpeg',
          createdAt: '2026-01-01T00:00:00',
          syncStatus: SyncStatus.enNube,
          fileId: h.fileIdString,
          thumbPath: thumbRel,
          thumbFileId: CryptoService.fileIdOfHeader(thumb),
        ),
      );
      return (await env.items.getItem(id))!;
    }

    VaultMediaOpener opener(VaultSession s) => VaultMediaOpener(
      fetcher: env.fetcher,
      filesKey: s.filesKeyFor,
      temp: PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir),
      streaming: false,
    );

    test('el visor abre cada item con la llave de su generación', () async {
      // Un item de la gen 1 (cifrado con la llave anterior).
      final p1 = _bytes(3000, 1);
      final f1 = env.localFile('g1');
      final src = File('${f1.path}.plain')..writeAsBytesSync(p1);
      final h = await env.crypto.encryptFile(
        src,
        f1,
        env.session.filesKeyFor(1)!,
      );
      src.deleteSync();
      await env.items.insertItem(
        VaultItemModel(
          keyGen: 1,
          id: 'g1',
          name: 'a.jpg',
          encryptedPath: AppPaths.vaultRelativePath('g1'),
          fileSize: p1.length,
          mimeType: 'image/jpeg',
          createdAt: '2026-01-01T00:00:00',
          fileId: h.fileIdString,
        ),
      );
      final p2 = _bytes(5000, 2);
      final i2 = await addGen2('g2', p2);

      final o = opener(env.session);
      expect(await o.loadImage((await env.items.getItem('g1'))!), p1);
      expect(await o.loadImage(i2), p2);
    });

    test('modelo viejo de la cuadrícula: se usa la fila fresca', () async {
      final plain = _bytes(4000, 3);
      final fresh = await addGen2('g3', plain);
      // La cuadrícula aún tiene el modelo de ANTES del re-cifrado.
      final stale = VaultItemModel(
        keyGen: 1,
        id: 'g3',
        name: fresh.name,
        encryptedPath: AppPaths.vaultRelativePath('g3'),
        fileSize: fresh.fileSize,
        mimeType: fresh.mimeType,
        createdAt: fresh.createdAt,
        fileId: 'otro-file-id',
        thumbPath: AppPaths.thumbRelativePath('g3'),
      );
      expect(await opener(env.session).loadImage(stale), plain);

      final loader = EncryptedThumbnailLoader(
        thumbsKey: env.session.thumbsKeyFor,
        refresh: env.items.getItem,
      );
      expect(await loader.load(stale), [7, 7, 7]);
      // Sin refresco no hay reintento (la miniatura vieja no existe).
      final plainLoader = EncryptedThumbnailLoader(
        thumbsKey: env.session.thumbsKeyFor,
      );
      expect(await plainLoader.load(stale), isNull);
    });

    test('una sesión sin esa generación no la abre', () async {
      final i2 = await addGen2('g4', _bytes(100, 4));
      final only1 = VaultSession.create()..open(await _keys(1));
      await expectLater(
        opener(only1).loadImage(i2),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'regenerar la miniatura de un item gen 2 usa su llave y nombre',
      () async {
        final i2 = await addGen2('g5', _bytes(100, 5));
        AppPaths.resolve(i2.thumbPath!).deleteSync();
        await (await env.vdb.database).update('vault_items', {
          'sourceAssetId': 'asset-g5',
        }, where: "id = 'g5'");
        final source = _AssetThumbs();
        final regen = ThumbnailRegenerationService(
          repository: env.items,
          source: source,
          videoThumbnailer: _NoFrames(),
          filesKey: env.session.filesKeyFor,
          thumbsKey: env.session.thumbsKeyFor,
          tempDirProvider: () => Directory(p.join(env.tmp.path, 'regen')),
        );
        final r = await regen.run(manual: true);
        expect(r.regenerated, 1);
        final after = (await env.items.getItem('g5'))!;
        expect(after.thumbPath, AppPaths.thumbRelativePath('g5', gen: 2));
        final enc = AppPaths.resolve(after.thumbPath!).readAsBytesSync();
        expect(await env.crypto.decryptBytes(enc, k2.thumbs), source.bytes);
      },
    );

    test('actualizaciones condicionales (M4)', () async {
      final i2 = await addGen2('g6', _bytes(100, 6));
      // Con la generación/ruta de antes: no toca nada.
      expect(
        await env.items.markCloudVerifiedIf(
          'g6',
          driveFileId: 'd',
          md5: 'm',
          size: 1,
          expectKeyGen: 1,
          expectPath: AppPaths.vaultRelativePath('g6'),
        ),
        isFalse,
      );
      expect(
        await env.items.updateSyncStatusIf(
          'g6',
          SyncStatus.enCache,
          expectKeyGen: 1,
          expectPath: AppPaths.vaultRelativePath('g6'),
        ),
        isFalse,
      );
      expect((await env.items.getItem('g6'))!.driveFileId, isNull);
      expect((await env.items.getItem('g6'))!.syncStatus, SyncStatus.enNube);
      // Con las actuales sí.
      expect(
        await env.items.markCloudVerifiedIf(
          'g6',
          driveFileId: 'd2',
          md5: 'm2',
          size: 2,
          expectKeyGen: 2,
          expectPath: i2.encryptedPath,
        ),
        isTrue,
      );
      expect((await env.items.getItem('g6'))!.driveFileId, 'd2');
      // Item inexistente: false, sin lanzar.
      expect(
        await env.items.updateSyncStatusIf(
          'nada',
          SyncStatus.enCache,
          expectKeyGen: 2,
          expectPath: 'vault/nada.vault',
        ),
        isFalse,
      );
      expect((await env.items.getItemsByKeyGen(2)).map((i) => i.id), ['g6']);
    });
  });
}

/// Fototeca que solo sabe dar miniaturas.
class _AssetThumbs implements GalleryAssetSource {
  final bytes = Uint8List.fromList([0xFF, 0xD8, 9, 9, 0xFF, 0xD9]);

  @override
  Future<Uint8List?> thumbnail(String assetId, {int size = 256}) async => bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoFrames implements VideoThumbnailer {
  @override
  Future<Uint8List?> thumbnail(File video, {int size = 256}) async => null;
}
