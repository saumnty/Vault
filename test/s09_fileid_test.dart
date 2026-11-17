// Regresión S-09: cada item/miniatura guarda el fileId del encabezado de su
// .vault/.thumb y se verifica al abrir, descargar, hacer streaming y restaurar.
// Un archivo auténtico de la misma bóveda pero de OTRO item se trata como
// dañado. Con el código anterior estos casos no detectaban el intercambio.
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/features/vault/services/thumbnail_loader.dart';
import 'package:vault/core/services/app_paths.dart';

import 'support/f6_env.dart';
import 'support/f9_env.dart';

Future<Uint8List> _cloudBytes(F6Env env, String id) async {
  final meta = await env.cloud.findByName('$id.vault');
  final tmp = File('${env.tmp.path}/dl_$id');
  await env.cloud.download(meta!.id, tmp);
  return tmp.readAsBytes();
}

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 7 + seed) & 0xFF));

void main() {
  final crypto = CryptoService();
  final key = SecretKey(List.generate(32, (i) => i + 1));

  group('formato / CryptoService', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('s09'));
    tearDown(() => dir.delete(recursive: true));

    Future<(File, String)> enc(String name, int seed) async {
      final src = File('${dir.path}/$name.plain')
        ..writeAsBytesSync(_bytes(5000, seed));
      final dst = File('${dir.path}/$name.vault');
      final h = await crypto.encryptFile(src, dst, key);
      return (dst, h.fileIdString);
    }

    test(
      'openReader: el fileId correcto abre; otro .vault auténtico falla',
      () async {
        final (a, idA) = await enc('a', 1);
        final (b, idB) = await enc('b', 2);
        expect(idA, isNot(idB));
        final ok = await crypto.openReader(a, key, expectedFileId: idA);
        expect(await ok.readRange(0, 10), _bytes(5000, 1).sublist(0, 10));
        await ok.close();
        // b es auténtico (misma llave) pero no es el registrado para a.
        await expectLater(
          crypto.openReader(b, key, expectedFileId: idA),
          throwsA(isA<VaultFileMismatchException>()),
        );
        // Sin fileId esperado no se comprueba (compatibilidad).
        await (await crypto.openReader(b, key)).close();
      },
    );

    test('decryptBytes (miniaturas): intercambio detectado', () async {
      final t1 = await crypto.encryptBytes(_bytes(300, 1), key);
      final t2 = await crypto.encryptBytes(_bytes(300, 2), key);
      final id1 = CryptoService.fileIdOfHeader(t1);
      expect(
        await crypto.decryptBytes(t1, key, expectedFileId: id1),
        _bytes(300, 1),
      );
      await expectLater(
        crypto.decryptBytes(t2, key, expectedFileId: id1),
        throwsA(isA<VaultFileMismatchException>()),
      );
    });

    test(
      'VaultFileMismatchException es un error de cifrado (UI: archivo dañado)',
      () {
        expect(const VaultFileMismatchException(), isA<VaultCryptoException>());
      },
    );
  });

  group('descarga (VaultFileFetcher)', () {
    late F6Env env;
    setUp(() async {
      env = F6Env();
      await env.setUp();
    });
    tearDown(() => env.tearDown());

    test(
      'el .vault de Drive con otro fileId se rechaza y no se instala',
      () async {
        await env.addCloudItem('a', plain: _bytes(3000, 1), keepLocal: false);
        // Drive devuelve para "b" el .vault (auténtico) de "a": mismo tamaño,
        // MD5 coherente con lo registrado; solo el fileId delata el cambio.
        final aVault = await _cloudBytes(env, 'a');
        await env.addCloudItem(
          'b',
          plain: _bytes(3000, 2),
          cloudBytes: aVault,
          keepLocal: false,
        );
        final item = (await env.items.getItem('b'))!;
        expect(item.fileId, isNotNull);
        await expectLater(
          env.fetcher.ensureLocal(item),
          throwsA(isA<VaultFetchVerificationException>()),
        );
        expect(env.localFile('b').existsSync(), isFalse);
        expect(File('${env.localFile('b').path}.part').existsSync(), isFalse);
      },
    );

    test('el .vault correcto (mismo fileId) se instala', () async {
      await env.addCloudItem('a', plain: _bytes(3000, 1), keepLocal: false);
      final item = (await env.items.getItem('a'))!;
      expect(item.fileId, isNotNull);
      final f = await env.fetcher.ensureLocal(item);
      expect(f.existsSync(), isTrue);
    });
  });

  group('miniaturas', () {
    test(
      'EncryptedThumbnailLoader: miniatura de otro item no se muestra',
      () async {
        final dir = await Directory.systemTemp.createTemp('s09t');
        addTearDown(() => dir.delete(recursive: true));
        final t1 = await crypto.encryptBytes(_bytes(200, 1), key);
        final t2 = await crypto.encryptBytes(_bytes(200, 2), key);
        // Archivo de la miniatura de i1, pero con el contenido de la de i2.
        final f = File('${dir.path}/i1.thumb')..writeAsBytesSync(t2);
        final loader = EncryptedThumbnailLoader(
          thumbsKey: () => key,
          crypto: crypto,
          resolve: (_) => f,
        );
        VaultItemModel item(String thumbFileId) => VaultItemModel(
          keyGen: 1,
          id: 'i1',
          name: 'n',
          encryptedPath: 'vault/i1.vault',
          fileSize: 1,
          mimeType: 'image/jpeg',
          createdAt: '2026-01-01T00:00:00',
          thumbPath: 'thumbs/i1.thumb',
          thumbFileId: thumbFileId,
        );
        expect(
          await loader.load(item(CryptoService.fileIdOfHeader(t1))),
          isNull,
        );
        loader.clear();
        expect(
          await loader.load(item(CryptoService.fileIdOfHeader(t2))),
          _bytes(200, 2),
        );
      },
    );
  });

  group('restauración (snapshot con miniatura intercambiada en Drive)', () {
    test(
      'la miniatura que no es la registrada se descarta como perdida',
      () async {
        final a = PhoneA();
        await a.setUp();
        final b = PhoneB();
        var bUp = false;
        addTearDown(() async {
          if (bUp) await b.tearDown();
          await a.tearDown();
        });
        await a.addItem('i1', 'Uno.jpg', realThumb: true);
        await a.addItem('i2', 'Dos.jpg', realThumb: true);
        await a.syncAll();
        // Drive: i1.thumb pasa a contener la miniatura (auténtica) de i2.
        final t1 = a.cloud.byName('i1.thumb')!;
        final t2 = a.cloud.byName('i2.thumb')!;
        final tmpDl = File('${a.dir.path}/dl_i2.thumb');
        await a.cloud.download(t2.id, tmpDl);
        await a.cloud.uploadBytes(
          bytes: await tmpDl.readAsBytes(),
          name: 'i1.thumb',
          replaceFileId: t1.id,
        );
        await b.setUp(a.cloud, expectedPassword: a.passwordA);
        bUp = true;
        expect(await b.service.probe(), RestoreProbeResult.found);
        expect(await b.service.verifyCode(a.recoveryCode), isTrue);
        final r = await b.service.restore(newPin: '135700');
        expect(r.missingThumbnails, 1);
        expect(r.thumbnails, 1);
        expect(
          AppPaths.resolve(AppPaths.thumbRelativePath('i1')).existsSync(),
          isFalse,
        );
        expect(
          AppPaths.resolve(AppPaths.thumbRelativePath('i2')).existsSync(),
          isTrue,
        );
      },
    );
  });
}
