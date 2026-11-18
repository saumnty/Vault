// Entorno común de la batería de la fase 8 (DISENO_SENUELO §11.1): bóveda
// principal en un directorio temporal, almacén que puede "perder" escrituras
// (apply() de Android) y utilidades para comparar la principal byte a byte.
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';

import '../../support/fakes.dart';
import '../../support/rotation_env.dart' show DroppingStore;

const String pinPrimary = '111111';
const String pinSecondary = '482913';

class SecondaryEnv {
  late Directory base;
  final DroppingStore store;
  late VaultSession session;
  late AuthController auth;
  late String recoveryCode;

  SecondaryEnv({DroppingStore? store}) : store = store ?? DroppingStore();

  Future<void> setUp({bool createPrimary = true}) async {
    base = await Directory.systemTemp.createTemp('alt_env');
    await AppPaths.init(baseDir: base);
    session = VaultSession.create();
    auth = newAuth();
    if (createPrimary) {
      recoveryCode = (await auth.createVault(pinPrimary)).recoveryCode;
    }
  }

  AuthController newAuth() => AuthController(
    storage: store,
    biometricStore: FakeBiometricKeyStore(),
    kdfParams: fastKdf,
    session: session,
    excludeFromBackup: (_) async {},
  );

  Future<void> tearDown() async {
    session.clear();
    AppPaths.resetForTesting();
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> createSecondary() async {
    if (!session.isUnlockedAs(VaultSlot.primary)) {
      session.clear();
      await auth.unlockWithPin(pinPrimary);
    }
    final ok = await auth.createSecondaryVault(
      primaryPin: pinPrimary,
      newPin: pinSecondary,
    );
    if (!ok) throw StateError('no se creó la secundaria');
  }

  Future<bool> unlock(String pin) async {
    auth.lock();
    return auth.unlockWithPin(pin);
  }

  /// Claves del almacén que NO son de la secundaria (sin el contador de
  /// intentos, que es compartido y puede volver a su estado previo).
  Map<String, String> nonAltStore() => {
    for (final e in store.data.entries)
      if (!e.key.startsWith('vault.v1.alt.') &&
          e.key != 'vault.v1.pin_attempts')
        e.key: e.value,
  };

  /// Huella de todos los archivos de la PRINCIPAL (todo bajo la raíz menos
  /// `alt/`), por ruta relativa.
  Map<String, String> primaryFiles() =>
      _tree(base, skip: (rel) => rel == 'alt' || rel.startsWith('alt/'));

  /// Huella de los archivos de la SECUNDARIA (`alt/`).
  Map<String, String> secondaryFiles() {
    final root = VaultPaths.secondary.root;
    if (!root.existsSync()) return const {};
    return _tree(root);
  }

  static Map<String, String> _tree(
    Directory root, {
    bool Function(String rel)? skip,
  }) {
    final out = <String, String>{};
    for (final e in root.listSync(recursive: true).whereType<File>()) {
      final rel = p.relative(e.path, from: root.path).replaceAll('\\', '/');
      if (skip?.call(rel) ?? false) continue;
      out[rel] = crypto.sha256.convert(e.readAsBytesSync()).toString();
    }
    return out;
  }
}
