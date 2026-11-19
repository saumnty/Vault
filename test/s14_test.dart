// Regresión S-14: topes de tamaño en la restauración (respaldo de llaves,
// snapshot) y en las descargas de la nube.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/restore/restore_service.dart';

import 'support/f9_env.dart';
import 'support/fake_cloud.dart';

/// Nube que MIENTE en los metadatos (declara un tamaño pequeño).
class _LyingCloud extends FakeCloudStorage {
  @override
  Future<CloudFile?> findByName(String name) async {
    final f = await super.findByName(name);
    if (f == null) return null;
    return CloudFile(
      id: f.id,
      name: f.name,
      size: 10,
      md5Checksum: f.md5Checksum,
    );
  }
}

void main() {
  test('downloadBytes con maxBytes rechaza lo que lo excede', () async {
    final c = FakeCloudStorage();
    await c.signIn();
    final meta = await c.uploadBytes(bytes: Uint8List(100), name: 'x');
    expect((await c.downloadBytes(meta.id, maxBytes: 100)).length, 100);
    await expectLater(
      c.downloadBytes(meta.id, maxBytes: 99),
      throwsA(isA<CloudTooLargeException>()),
    );
  });

  group('probe', () {
    late PhoneA a;
    PhoneB? b;
    tearDown(() async {
      await b?.tearDown();
      await a.tearDown();
    });

    test('recovery_backup.json de más de 4 KiB: invalid', () async {
      a = PhoneA();
      await a.setUp();
      await a.cloud.uploadBytes(
        bytes: Uint8List.fromList(utf8.encode('{"a":"${'x' * 5000}"}')),
        name: 'recovery_backup.json',
      );
      b = PhoneB();
      await b!.setUp(a.cloud, expectedPassword: a.passwordA);
      expect(await b!.service.probe(), RestoreProbeResult.invalid);
    });

    test(
      'metadatos que mienten: los bytes recibidos también se topan',
      () async {
        a = PhoneA();
        await a.setUp();
        final lying = _LyingCloud();
        await lying.signIn();
        await lying.uploadBytes(
          bytes: Uint8List.fromList(utf8.encode('{"a":"${'x' * 5000}"}')),
          name: 'recovery_backup.json',
        );
        b = PhoneB();
        await b!.setUp(lying, expectedPassword: a.passwordA);
        expect(await b!.service.probe(), RestoreProbeResult.invalid);
      },
    );
  });

  test(
    'snapshot sobre el tope: la restauración falla con error claro',
    () async {
      final a = PhoneA();
      await a.setUp();
      await a.addItem('i1', 'a.jpg');
      await a.syncAll();
      final b = PhoneB();
      await b.setUp(a.cloud, expectedPassword: a.passwordA);
      addTearDown(() async {
        await b.tearDown();
        await a.tearDown();
      });
      expect(await b.service.probe(), RestoreProbeResult.found);
      expect(await b.service.verifyCode(a.recoveryCode), isTrue);
      final small = RestoreService(
        cloud: a.cloud,
        auth: b.auth,
        prefs: b.prefs,
        dbPath: b.dbPath,
        maxSnapshotBytes: 16,
      );
      // El respaldo ya probado vive en `b.service`; se repite el probe aquí.
      expect(await small.probe(), RestoreProbeResult.found);
      expect(await small.verifyCode(a.recoveryCode), isTrue);
      await expectLater(
        small.restore(newPin: '123456'),
        throwsA(isA<RestoreTooLargeException>()),
      );
      small.dispose();
    },
  );
}
