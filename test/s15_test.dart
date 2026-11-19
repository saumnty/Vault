// Regresión S-15: rutas de archivos de items estrictas y ids UUID.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';

const _id = '3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69';

void main() {
  setUp(() => AppPaths.allowNonUuidIdsForTesting = false);
  tearDown(() => AppPaths.allowNonUuidIdsForTesting = true);

  test('acepta exactamente vault/<uuid>.vault y thumbs/<uuid>.thumb', () {
    expect(AppPaths.validateRelative('vault/$_id.vault'), 'vault/$_id.vault');
    expect(AppPaths.validateRelative('thumbs/$_id.thumb'), 'thumbs/$_id.thumb');
    expect(
      AppPaths.validateRelative(AppPaths.vaultRelativePath(_id)),
      isNotEmpty,
    );
  });

  test('D60: acepta la generación de llave N ≥ 2 en el nombre', () {
    for (final gen in [2, 9, 10, 123, 9999]) {
      final v = AppPaths.vaultRelativePath(_id, gen: gen);
      final t = AppPaths.thumbRelativePath(_id, gen: gen);
      expect(v, 'vault/$_id.k$gen.vault');
      expect(AppPaths.validateRelative(v), v);
      expect(AppPaths.validateRelative(t), t);
    }
  });

  for (final bad in [
    'vault/../db/vault_secure.db',
    'db/vault_secure.db',
    'vault/${_id.toUpperCase()}.vault',
    'vault/sub/$_id.vault',
    'vault/$_id.thumb',
    'thumbs/$_id.vault',
    'vault/$_id.vault/',
    'vault/$_id.vault/..',
    'vault\\$_id.vault',
    '/vault/$_id.vault',
    'vault/i1.vault',
    'vault/a/../$_id.vault',
    'vault_cache/$_id.vault',
    // versión/variante inválidas (no v4)
    'vault/3f2b8c1e-9d4a-1b6f-8a7c-1e2d3c4b5a69.vault',
    '',
    // D60: sufijo de generación mal formado
    'vault/$_id.k1.vault',
    'vault/$_id.k0.vault',
    'vault/$_id.k02.vault',
    'vault/$_id.k10000.vault',
    'vault/$_id.K2.vault',
    'vault/$_id.k2.k3.vault',
    'vault/$_id.k.vault',
    'vault/$_id.k2.thumb',
    'thumbs/$_id.k2.vault',
    'vault/$_id.k2.vault.part',
    'vault/../$_id.k2.vault',
  ]) {
    test('rechaza "$bad"', () {
      expect(() => AppPaths.validateRelative(bad), throwsArgumentError);
    });
  }

  test('resolve rechaza rutas que salen de vault/ y thumbs/', () async {
    final dir = await Directory.systemTemp.createTemp('s15');
    addTearDown(() => dir.delete(recursive: true));
    await AppPaths.init(baseDir: dir);
    addTearDown(AppPaths.resetForTesting);
    expect(
      () => AppPaths.resolve('vault/../db/vault_secure.db'),
      throwsArgumentError,
    );
    expect(AppPaths.resolve('vault/$_id.vault').path, contains(_id));
  });

  test('isValidItemId: solo UUID v4 en minúsculas', () {
    expect(AppPaths.isValidItemId(_id), isTrue);
    expect(AppPaths.isValidItemId(_id.toUpperCase()), isFalse);
    expect(AppPaths.isValidItemId('../$_id'), isFalse);
    expect(AppPaths.isValidItemId('a/b'), isFalse);
    expect(AppPaths.isValidItemId('..'), isFalse);
    expect(AppPaths.isValidItemId(''), isFalse);
  });

  test('las rutas generales (BD, caché) siguen validándose aparte', () {
    expect(
      AppPaths.validateGenericRelative('db/vault_secure.db'),
      'db/vault_secure.db',
    );
    expect(() => AppPaths.validateGenericRelative('../x'), throwsArgumentError);
  });
}
