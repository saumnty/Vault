import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_slot.dart';
import 'package:vault/data/repositories/vault_database.dart';

/// Fase 8, paso 1 (DISENO_SENUELO §2.2): un resolutor de rutas por bóveda.
void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('vault_paths');
    await AppPaths.init(baseDir: base);
  });

  tearDown(() async {
    AppPaths.resetForTesting();
    if (base.existsSync()) await base.delete(recursive: true);
  });

  const uuid = '0b4c3a52-6f1e-4c2a-9d3b-7e8f9a0b1c2d';

  test('la principal resuelve EXACTAMENTE las rutas de siempre', () {
    final v = VaultPaths.primary;
    expect(v.slot, VaultSlot.primary);
    expect(v.root.path, base.path);
    expect(v.vaultDir.path, p.join(base.path, 'vault'));
    expect(v.thumbsDir.path, p.join(base.path, 'thumbs'));
    expect(v.dbDir.path, p.join(base.path, 'db'));
    expect(v.cacheDir.path, p.join(base.path, 'vault_cache'));
    expect(v.tmpPlainDir.path, p.join(base.path, 'vault_cache', 'tmp_plain'));
    expect(v.importTmpDir.path, p.join(base.path, 'vault_cache', 'import_tmp'));
    expect(v.dbFilePath, p.join(base.path, 'db', 'vault_secure.db'));
    // AppPaths delega en la principal: mismas rutas.
    expect(AppPaths.vaultDir.path, v.vaultDir.path);
    expect(AppPaths.thumbsDir.path, v.thumbsDir.path);
    expect(AppPaths.dbDir.path, v.dbDir.path);
    expect(AppPaths.cacheDir.path, v.cacheDir.path);
    expect(AppPaths.tmpPlainDir.path, v.tmpPlainDir.path);
    expect(VaultDatabase.defaultDbPath, v.dbFilePath);
    expect(VaultSchema.dbFileName, VaultPaths.dbFileName);
    expect(
      AppPaths.resolvePath('vault/$uuid.vault'),
      p.join(base.path, 'vault', '$uuid.vault'),
    );
  });

  test('la secundaria vive bajo alt/ con la misma forma', () {
    final v = VaultPaths.secondary;
    final alt = p.join(base.path, 'alt');
    expect(v.slot, VaultSlot.secondary);
    expect(v.root.path, alt);
    expect(v.vaultDir.path, p.join(alt, 'vault'));
    expect(v.thumbsDir.path, p.join(alt, 'thumbs'));
    expect(v.dbFilePath, p.join(alt, 'db', 'vault_secure.db'));
    expect(v.tmpPlainDir.path, p.join(alt, 'vault_cache', 'tmp_plain'));
    expect(
      v.resolvePath('thumbs/$uuid.thumb'),
      p.join(alt, 'thumbs', '$uuid.thumb'),
    );
    expect(
      v.relative(p.join(alt, 'vault', '$uuid.vault')),
      'vault/$uuid.vault',
    );
    expect(
      () => v.relative(p.join(base.path, 'vault', '$uuid.vault')),
      throwsArgumentError,
    );
    expect(VaultPaths.of(VaultSlot.secondary), same(v));
    expect(VaultPaths.of(VaultSlot.primary), same(VaultPaths.primary));
  });

  test('init no crea alt/; ensureDirs sí (solo al pedirlo)', () async {
    expect(VaultPaths.secondary.exists, isFalse);
    await AppPaths.init(); // idempotente
    expect(VaultPaths.secondary.exists, isFalse);
    VaultPaths.secondary.ensureDirs();
    for (final d in [
      VaultPaths.secondary.vaultDir,
      VaultPaths.secondary.thumbsDir,
      VaultPaths.secondary.dbDir,
      VaultPaths.secondary.cacheDir,
    ]) {
      expect(d.existsSync(), isTrue);
    }
  });

  test('S-15 rige igual en la secundaria', () {
    final prev = AppPaths.allowNonUuidIdsForTesting;
    AppPaths.allowNonUuidIdsForTesting = false;
    addTearDown(() => AppPaths.allowNonUuidIdsForTesting = prev);
    for (final bad in [
      '../vault/$uuid.vault',
      'vault/../$uuid.vault',
      '/abs/$uuid.vault',
      'db/vault_secure.db',
      'vault/i1.vault',
    ]) {
      expect(
        () => VaultPaths.secondary.resolvePath(bad),
        throwsArgumentError,
        reason: bad,
      );
    }
  });

  test('sin init lanza StateError', () {
    AppPaths.resetForTesting();
    expect(() => VaultPaths.secondary.root, throwsStateError);
  });
}
