// C1/A3 (D62, rotación de la DEK paso 2): decisión de arranque con iOS
// simulado. Nunca se descartan las llaves si quedan restos de una rotación.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/vault_bootstrap.dart';

import 'support/fakes.dart';

void main() {
  late Directory tmp;
  late InMemorySecureStore store;
  late AuthController auth;

  String dbPath() => VaultDatabase.defaultDbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bootstrap');
    await AppPaths.init(baseDir: tmp);
    store = InMemorySecureStore();
    auth = AuthController(
      storage: store,
      biometricStore: FakeBiometricKeyStore(),
      kdfParams: fastKdf,
      session: VaultSession.create(),
    );
  });

  tearDown(() async {
    auth.lock();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> createVaultWithDb() async {
    await auth.createVault('123456');
    File(dbPath()).writeAsBytesSync([1, 2, 3]);
    store.data[AuthController.dbCreatedKey] = 'true';
  }

  test('sin bóveda: onboarding y barrido de huérfanos', () async {
    File(dbPath()).writeAsBytesSync([1]);
    final thumb = File(p.join(AppPaths.thumbsDir.path, 'x.thumb'))
      ..writeAsBytesSync([1]);
    expect(await VaultBootstrap.decide(auth: auth, isIOS: true), isFalse);
    expect(File(dbPath()).existsSync(), isFalse);
    expect(thumb.existsSync(), isFalse);
  });

  test('con bóveda y BD: va al PIN (iOS y Android)', () async {
    await createVaultWithDb();
    for (final ios in [true, false]) {
      expect(await VaultBootstrap.decide(auth: auth, isIOS: ios), isTrue);
    }
    expect(await auth.hasVault(), isTrue);
    expect(File(dbPath()).existsSync(), isTrue);
  });

  test(
    'iOS reinstalada (Keychain sin archivos): descarta llaves y marca',
    () async {
      await createVaultWithDb();
      File(dbPath()).deleteSync();
      expect(await VaultBootstrap.decide(auth: auth, isIOS: true), isFalse);
      expect(await auth.hasVault(), isFalse);
      expect(store.data[AuthController.dbCreatedKey], isNull);
    },
  );

  test('Android sin BD: nunca descarta llaves', () async {
    await createVaultWithDb();
    File(dbPath()).deleteSync();
    expect(await VaultBootstrap.decide(auth: auth, isIOS: false), isTrue);
    expect(await auth.hasVault(), isTrue);
  });

  for (final leftover in [
    'vault_secure.db.k1',
    'vault_secure.db.k2.tmp',
    'vault_secure.db.k12.tmp',
  ]) {
    test('iOS sin BD pero con "$leftover": NO descarta llaves', () async {
      await createVaultWithDb();
      final rest = File(p.join(AppPaths.dbDir.path, leftover))
        ..writeAsBytesSync([9, 9]);
      File(dbPath()).deleteSync();
      expect(await VaultBootstrap.decide(auth: auth, isIOS: true), isTrue);
      expect(await auth.hasVault(), isTrue);
      expect(store.data[AuthController.dbCreatedKey], 'true');
      expect(rest.existsSync(), isTrue, reason: 'no se barre nada');
    });
  }

  test('otros archivos en db/ no cuentan como restos de rotación', () async {
    await createVaultWithDb();
    File(
      p.join(AppPaths.dbDir.path, 'vault_secure.db.snapshot'),
    ).writeAsBytesSync([1]);
    File(
      p.join(AppPaths.dbDir.path, 'vault_secure.db.kx'),
    ).writeAsBytesSync([1]);
    File(dbPath()).deleteSync();
    expect(VaultBootstrap.hasRotationLeftovers(dbPath()), isFalse);
    expect(await VaultBootstrap.decide(auth: auth, isIOS: true), isFalse);
  });

  test('onboarding pendiente: no descarta aunque falte la BD', () async {
    await auth.createVault('123456', onboardingPending: true);
    expect(await VaultBootstrap.decide(auth: auth, isIOS: true), isTrue);
  });
}
