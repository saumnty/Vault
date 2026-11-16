// Regresión S-05: al bloquear se vacía el ImageCache global y se ponen a cero
// los buffers en claro propios.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/session/image_cache_wipe.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/vault/services/thumbnail_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('wipeImageCache vacía el ImageCache global al bloquear', () {
    final cache = PaintingBinding.instance.imageCache;
    final session = VaultSession.create()..addOnClear(wipeImageCache);
    cache.putIfAbsent(
      'k',
      () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
    );
    expect(cache.statusForKey('k').pending, isTrue);
    session.clear();
    expect(cache.statusForKey('k').tracked, isFalse);
    expect(cache.liveImageCount, 0);
  });

  test('zeroFill sobrescribe con ceros', () {
    final b = Uint8List.fromList([1, 2, 3]);
    zeroFill(b);
    expect(b, [0, 0, 0]);
    zeroFill(null);
  });

  test(
    'EncryptedThumbnailLoader.clear pone a cero los bytes en caché',
    () async {
      final crypto = CryptoService();
      final key = SecretKey(List<int>.generate(32, (i) => i));
      final dir = Directory.systemTemp.createTempSync('s05');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/t.thumb')
        ..writeAsBytesSync(
          await crypto.encryptBytes(Uint8List.fromList([9, 9, 9, 9]), key),
        );
      final loader = EncryptedThumbnailLoader(
        thumbsKey: () => key,
        crypto: crypto,
        resolve: (_) => f,
      );
      final item = VaultItemModel(
        id: 'i1',
        name: 'n',
        encryptedPath: 'vault/i1.vault',
        fileSize: 1,
        mimeType: 'image/jpeg',
        createdAt: '2026-01-01T00:00:00Z',
        thumbPath: 't',
      );
      final bytes = (await loader.load(item))!;
      expect(bytes, [9, 9, 9, 9]);
      loader.clear();
      expect(bytes, [0, 0, 0, 0]);
      expect(loader.cachedCount, 0);
    },
  );
}
