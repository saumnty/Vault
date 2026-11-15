import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/core/streaming/vault_stream_server.dart';

import 'support/fakes.dart';

// Archivo aparte: TestWidgetsFlutterBinding sustituye HttpClient por uno que
// responde 400 y aquí hace falta un socket real contra el servidor loopback.
void main() {
  group('Bloqueo: temporales en claro y servidor de streaming', () {
    test('clear borra temporales y cierra el servidor loopback', () async {
      final tmp = await Directory.systemTemp.createTemp('f7_lock');
      addTearDown(() => tmp.delete(recursive: true));
      final session = VaultSession.create();
      final temp = PlainTempManager(
        dirProvider: () => Directory('${tmp.path}/plain'),
      );
      session.addOnClear(temp.purgeSync);
      session.addOnClear(VaultStreamServer.closeAllNow);
      final c = AuthController(
        storage: InMemorySecureStore(),
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: session,
      );
      await c.createVault('123456');

      final plainFile = temp.newTempFile(extension: '.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      expect(plainFile.existsSync(), isTrue);

      final key = SecretKey(List.generate(32, (i) => i));
      final src = File('${tmp.path}/p.bin')
        ..writeAsBytesSync(List.filled(5000, 7));
      final enc = File('${tmp.path}/v.vault');
      await VaultFileFormat().encryptFile(src, enc, key, blockSize: 4096);
      final server = await VaultStreamServer.start(
        reader: await VaultFileReader.open(enc, key),
        mimeType: 'video/mp4',
      );
      final client = HttpClient();
      final ok = await (await client.getUrl(server.uri)).close();
      expect(ok.statusCode, 200);
      await ok.drain<void>();

      c.lock(); // lo que hace el autobloqueo / "Bloquear ahora"

      expect(plainFile.existsSync(), isFalse, reason: 'sin texto plano');
      expect(temp.directory.listSync(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      Object? error;
      try {
        final r = await (await client.getUrl(server.uri)).close();
        await r.drain<void>();
      } on Object catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'el servidor ya no responde');
      client.close(force: true);
    });
  });
}
