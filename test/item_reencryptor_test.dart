// §5 (rotación de la DEK, paso 8): re-cifrado de un item con verificación
// SHA-256, encabezado nuevo, miniatura, fuente de respaldo en Drive y fila
// condicional. Nunca hay texto en claro en disco.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/crypto/aes_gcm_backend.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/vault_file_format.dart' show VaultByteSource;
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/rotation/item_reencryptor.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart' show md5OfBytes, md5OfFile;

import 'support/f6_env.dart';

/// Contenido reconocible para buscarlo en disco.
Uint8List _plain(int n) {
  final marker = utf8.encode('CLARO-SECRETO-');
  return Uint8List.fromList(List.generate(n, (i) => marker[i % marker.length]));
}

Future<String> _sha(List<int> b) async => (await Sha256().hash(
  b,
)).bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Repositorio que cambia la fila justo antes del cambio de generación.
class _RacingRepo extends VaultDataRepository {
  _RacingRepo(Future<dynamic> Function() db, this.race)
    : super(dbProvider: () async => await db());
  final Future<void> Function(String id) race;

  @override
  Future<bool> swapItemGeneration(
    String id, {
    required int fromGen,
    required String fromPath,
    required int toGen,
    required String encryptedPath,
    required String fileId,
    required String? thumbPath,
    required String? thumbFileId,
    required int nowMs,
  }) async {
    await race(id);
    return super.swapItemGeneration(
      id,
      fromGen: fromGen,
      fromPath: fromPath,
      toGen: toGen,
      encryptedPath: encryptedPath,
      fileId: fileId,
      thumbPath: thumbPath,
      thumbFileId: thumbFileId,
      nowMs: nowMs,
    );
  }
}

void main() {
  wipeRegressionTests();
  late F6Env env;
  late KeyHierarchy k1;
  late KeyHierarchy k2;
  final crypto = CryptoService();
  final thumbPlain = Uint8List.fromList(utf8.encode('MINIATURA-CLARA-1234'));

  setUp(() async {
    env = F6Env();
    await env.setUp();
    k1 = env.session.keys;
    k2 = await KeyHierarchy.fromDek(
      Uint8List.fromList(List.generate(32, (i) => 200 - i)),
    );
  });
  tearDown(() => env.tearDown());

  ItemReencryptor reencryptor({
    VaultDataRepository? repo,
    bool Function(String)? inUse,
  }) => ItemReencryptor(
    items: repo ?? env.items,
    cloud: env.cloud,
    workDir: () => Directory(p.join(AppPaths.cacheDir.path, 'rotation')),
    isInUse: inUse,
    nowMs: () => 42,
  );

  /// Item gen 1 con `.vault` y `.thumb` reales; opcionalmente en Drive.
  Future<VaultItemModel> addItem(
    String id,
    Uint8List plain, {
    bool thumb = true,
    bool inCloud = false,
    String? contentHash,
  }) async {
    final rel = AppPaths.vaultRelativePath(id);
    final file = AppPaths.resolve(rel);
    final h = await crypto.encryptSource(_Bytes(plain), file, k1.files);
    String? thumbRel;
    String? thumbFileId;
    String? thumbDrive;
    if (thumb) {
      thumbRel = AppPaths.thumbRelativePath(id);
      final enc = await crypto.encryptBytes(thumbPlain, k1.thumbs);
      AppPaths.resolve(thumbRel).writeAsBytesSync(enc);
      thumbFileId = CryptoService.fileIdOfHeader(enc);
      if (inCloud) {
        thumbDrive = (await env.cloud.uploadBytes(
          bytes: enc,
          name: '$id.thumb',
        )).id;
      }
    }
    String? driveId;
    String? md5;
    int? size;
    if (inCloud) {
      final bytes = file.readAsBytesSync();
      driveId = (await env.cloud.uploadBytes(
        bytes: bytes,
        name: '$id.vault',
      )).id;
      md5 = md5OfBytes(bytes);
      size = bytes.length;
    }
    await env.items.insertItem(
      VaultItemModel(
        keyGen: 1,
        id: id,
        name: '$id.jpg',
        encryptedPath: rel,
        fileSize: plain.length,
        mimeType: 'image/jpeg',
        createdAt: '2026-01-01T00:00:00',
        syncStatus: inCloud ? SyncStatus.enNube : SyncStatus.pendiente,
        contentHash: contentHash ?? await _sha(plain),
        fileId: h.fileIdString,
        thumbPath: thumbRel,
        thumbFileId: thumbFileId,
        driveFileId: driveId,
        cloudMd5: md5,
        cloudSize: size,
        thumbDriveFileId: thumbDrive,
      ),
    );
    return (await env.items.getItem(id))!;
  }

  Future<ReencryptResult> run(VaultItemModel item, {ItemReencryptor? r}) =>
      (r ?? reencryptor()).reencrypt(
        item,
        fromGen: 1,
        from: k1,
        toGen: 2,
        to: k2,
      );

  Future<Uint8List> openNew(VaultItemModel row) async {
    final reader = await crypto.openReader(
      AppPaths.resolve(row.encryptedPath),
      k2.files,
      expectedFileId: row.fileId,
    );
    try {
      return await reader.readRange(0, reader.plaintextLength);
    } finally {
      await reader.close();
    }
  }

  /// Ningún archivo bajo la carpeta de la app contiene el claro.
  void expectNoPlaintextOnDisk(List<Uint8List> plains) {
    final markers = [
      utf8.encode('CLARO-SECRETO-CLARO'),
      utf8.encode('MINIATURA-CLARA'),
    ];
    for (final f in env.tmp.listSync(recursive: true).whereType<File>()) {
      final bytes = f.readAsBytesSync();
      for (final m in markers) {
        expect(
          _contains(bytes, m),
          isFalse,
          reason: 'texto en claro en ${p.basename(f.path)}',
        );
      }
    }
  }

  test(
    'con un AES que devuelve vistas de SOLO LECTURA (como el nativo)',
    () async {
      final plain = _plain(2 * 1024 * 1024 + 5);
      final item = await addItem('ro1', plain);
      final old = AesGcmBackend.current;
      AesGcmBackend.current = _ReadOnlyBackend(DartAesGcmBackend());
      addTearDown(() => AesGcmBackend.current = old);
      final r = await run(item);
      expect(r.outcome, ReencryptOutcome.done);
      AesGcmBackend.current = old;
      expect(await openNew((await env.items.getItem(item.id))!), plain);
    },
  );

  for (final size in [0, 1, 1024 * 1024, 3 * 1024 * 1024 + 1]) {
    test(
      're-cifra $size B: mismo claro, encabezado nuevo, fila y cola',
      () async {
        final plain = _plain(size);
        final item = await addItem('s$size', plain);
        final r = await run(item);
        expect(r.outcome, ReencryptOutcome.done);
        final row = (await env.items.getItem(item.id))!;
        expect(row.keyGen, 2);
        expect(row.encryptedPath, AppPaths.vaultRelativePath(item.id, gen: 2));
        expect(row.thumbPath, AppPaths.thumbRelativePath(item.id, gen: 2));
        expect(row.fileId, isNot(item.fileId));
        expect(row.syncStatus, SyncStatus.pendiente);
        expect(row.driveFileId, isNull);
        expect(row.contentHash, item.contentHash);
        expect(await openNew(row), plain);
        final newFile = AppPaths.resolve(row.encryptedPath);
        expect(r.size, newFile.lengthSync());
        expect(r.md5, await md5OfFile(newFile));
        // La llave vieja ya no lo abre.
        await expectLater(
          crypto.openReader(newFile, k1.files),
          throwsA(isA<VaultCryptoException>()),
        );
        // Miniatura re-cifrada.
        expect(
          await crypto.decryptBytes(
            AppPaths.resolve(row.thumbPath!).readAsBytesSync(),
            k2.thumbs,
            expectedFileId: row.thumbFileId,
          ),
          thumbPlain,
        );
        // Archivos de la gen 1 borrados.
        expect(AppPaths.resolve(item.encryptedPath).existsSync(), isFalse);
        expect(AppPaths.resolve(item.thumbPath!).existsSync(), isFalse);
        // Trabajos de subida rehechos.
        final kinds = (await env.queue.all())
            .where((j) => j.itemId == item.id)
            .map((j) => j.kind)
            .toSet();
        expect(kinds, {SyncJobKind.file, SyncJobKind.thumb});
        expectNoPlaintextOnDisk([plain]);
        // Reanudación: ya hecho.
        expect((await run(row)).outcome, ReencryptOutcome.alreadyDone);
      },
    );
  }

  test('copia local dañada: se usa la de Drive', () async {
    final plain = _plain(200 * 1024);
    final item = await addItem('d1', plain, inCloud: true);
    final f = AppPaths.resolve(item.encryptedPath);
    final bytes = f.readAsBytesSync();
    bytes[bytes.length - 5] ^= 0xFF;
    f.writeAsBytesSync(bytes);
    final r = await run(item);
    expect(r.outcome, ReencryptOutcome.done);
    expect(await openNew((await env.items.getItem('d1'))!), plain);
    expect(
      Directory(p.join(AppPaths.cacheDir.path, 'rotation')).listSync().isEmpty,
      isTrue,
      reason: 'la fuente bajada se borra',
    );
    expectNoPlaintextOnDisk([plain]);
  });

  test('sin copia local: se baja de Drive (y la miniatura también)', () async {
    final plain = _plain(70 * 1024);
    final item = await addItem('d2', plain, inCloud: true);
    AppPaths.resolve(item.encryptedPath).deleteSync();
    AppPaths.resolve(item.thumbPath!).deleteSync();
    final r = await run(item);
    expect(r.outcome, ReencryptOutcome.done);
    expect(r.thumbLost, isFalse);
    final row = (await env.items.getItem('d2'))!;
    expect(await openNew(row), plain);
    expect(row.thumbPath, isNotNull);
  });

  test('copia local y de Drive dañadas: corrupt y nada cambia', () async {
    final item = await addItem('x1', _plain(5000), inCloud: true);
    final f = AppPaths.resolve(item.encryptedPath);
    final bytes = f.readAsBytesSync()..[40] ^= 1;
    f.writeAsBytesSync(bytes);
    env.cloud.corruptContent(item.driveFileId!);
    final r = await run(item);
    expect(r.outcome, ReencryptOutcome.corrupt);
    final row = (await env.items.getItem('x1'))!;
    expect(row.keyGen, 1);
    expect(row.encryptedPath, item.encryptedPath);
    expect(
      AppPaths.resolve(AppPaths.vaultRelativePath('x1', gen: 2)).existsSync(),
      isFalse,
    );
    expect(f.existsSync(), isTrue, reason: 'no se borra la única copia');
  });

  test('sin ninguna copia: missing y nada cambia', () async {
    final item = await addItem('x2', _plain(10));
    AppPaths.resolve(item.encryptedPath).deleteSync();
    expect((await run(item)).outcome, ReencryptOutcome.missing);
    expect((await env.items.getItem('x2'))!.keyGen, 1);
  });

  test('copia de Drive borrada (404) y sin local: missing', () async {
    final item = await addItem('x4', _plain(10), inCloud: true);
    AppPaths.resolve(item.encryptedPath).deleteSync();
    await env.cloud.delete(item.driveFileId!);
    expect((await run(item)).outcome, ReencryptOutcome.missing);
  });

  test('local dañada y sin copia en Drive: missing', () async {
    final item = await addItem('x5', _plain(5000));
    final f = AppPaths.resolve(item.encryptedPath);
    f.writeAsBytesSync(f.readAsBytesSync()..[40] ^= 1);
    expect((await run(item)).outcome, ReencryptOutcome.missing);
    expect(f.existsSync(), isTrue, reason: 'el reencryptor no borra nada');
  });

  test('contentHash distinto: corrupt (no se registra nada)', () async {
    final item = await addItem('x3', _plain(3000), contentHash: 'ab' * 32);
    final r = await run(item);
    expect(r.outcome, ReencryptOutcome.corrupt);
    expect(r.detail, contains('contentHash'));
    expect((await env.items.getItem('x3'))!.keyGen, 1);
    expect(
      AppPaths.resolve(AppPaths.vaultRelativePath('x3', gen: 2)).existsSync(),
      isFalse,
    );
  });

  test(
    'M4: la fila cambia antes del cambio: changed y se borra lo nuevo',
    () async {
      final item = await addItem('r1', _plain(4000));
      final repo = _RacingRepo(() => env.vdb.database, (id) async {
        await env.items.renameItem(id, 'otro.jpg'); // no cambia la ruta
        await (await env.vdb.database).update('vault_items', {
          'encryptedPath': 'vault/r1.otro.vault',
        }, where: "id = 'r1'");
      });
      final r = await run(item, r: reencryptor(repo: repo));
      expect(r.outcome, ReencryptOutcome.changed);
      expect(
        AppPaths.resolve(AppPaths.vaultRelativePath('r1', gen: 2)).existsSync(),
        isFalse,
      );
      expect((await env.items.getItem('r1'))!.keyGen, 1);
    },
  );

  test('otra generación o borrado: no toca nada', () async {
    final item = await addItem('g', _plain(10));
    await env.items.deleteItem('g');
    expect((await run(item)).outcome, ReencryptOutcome.changed);
  });

  test('en uso (visor): el .vault viejo se aplaza', () async {
    final item = await addItem('u1', _plain(3000));
    final r = await run(item, r: reencryptor(inUse: (id) => id == 'u1'));
    expect(r.outcome, ReencryptOutcome.done);
    expect(r.deferredDeletes, [item.encryptedPath]);
    expect(AppPaths.resolve(item.encryptedPath).existsSync(), isTrue);
  });

  test('miniatura irrecuperable: el item sigue, sin miniatura (L5)', () async {
    final item = await addItem('t1', _plain(3000));
    AppPaths.resolve(item.thumbPath!).deleteSync();
    final r = await run(item);
    expect(r.outcome, ReencryptOutcome.done);
    expect(r.thumbLost, isTrue);
    final row = (await env.items.getItem('t1'))!;
    expect(row.thumbPath, isNull);
    expect(row.thumbFileId, isNull);
    final kinds = (await env.queue.all())
        .where((j) => j.itemId == 't1')
        .map((j) => j.kind);
    expect(kinds, [SyncJobKind.file]);
  });
}

class _Bytes implements VaultByteSource {
  _Bytes(this._data);
  final Uint8List _data;
  int _pos = 0;
  @override
  Future<Uint8List> read(int length) async {
    final end = (_pos + length).clamp(0, _data.length);
    final out = Uint8List.sublistView(_data, _pos, end);
    _pos = end;
    return out;
  }
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

// Regresión (prueba real de la fase 1 en el emulador): con el AES nativo el
// bloque en claro es una vista de SOLO LECTURA y fillRange lanzaba
// UnsupportedError, dejando la rotación en pausa.
void wipeRegressionTests() {
  test('wipeBlock tolera vistas de solo lectura y borra las modificables', () {
    final ro = Uint8List.fromList([1, 2, 3]).asUnmodifiableView();
    wipeBlock(ro); // no lanza
    expect(ro, [1, 2, 3]);
    final rw = Uint8List.fromList([1, 2, 3]);
    wipeBlock(rw);
    expect(rw, [0, 0, 0]);
  });
}

/// AES que devuelve el claro como vista NO modificable (lo que hace el
/// backend nativo en Android/iOS) para cazar escrituras sobre ese claro.
class _ReadOnlyBackend implements AesGcmBackend {
  _ReadOnlyBackend(this._inner);
  final AesGcmBackend _inner;

  @override
  String get name => 'solo-lectura';

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  }) => _inner.encrypt(clearText, secretKey: secretKey, nonce: nonce, aad: aad);

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  }) async {
    final out = await _inner.decrypt(secretBox, secretKey: secretKey, aad: aad);
    return Uint8List.fromList(out).asUnmodifiableView();
  }
}
