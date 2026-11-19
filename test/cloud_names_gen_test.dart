// D60 (rotación de la DEK, paso 1): nombres por generación de llave.
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_names.dart';

const _id = '3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69';

void main() {
  setUp(() => AppPaths.allowNonUuidIdsForTesting = false);
  tearDown(() => AppPaths.allowNonUuidIdsForTesting = true);

  group('generación 1 = nombres de siempre (bóveda real del iPhone)', () {
    test('Drive', () {
      expect(CloudNames.file(_id), '$_id.vault');
      expect(CloudNames.thumb(_id), '$_id.thumb');
      expect(CloudNames.file(_id, gen: 1), '$_id.vault');
      expect(CloudNames.recoveryBackupFor(1), CloudNames.recoveryBackup);
      expect(CloudNames.recoveryBackup, 'recovery_backup.json');
      expect(CloudNames.dbSnapshotFor(1), CloudNames.dbSnapshot);
      expect(CloudNames.dbSnapshot, 'vault_db.snapshot');
    });

    test('local', () {
      expect(AppPaths.vaultRelativePath(_id), 'vault/$_id.vault');
      expect(AppPaths.thumbRelativePath(_id), 'thumbs/$_id.thumb');
      expect(AppPaths.vaultRelativePath(_id, gen: 1), 'vault/$_id.vault');
    });
  });

  group('generación N ≥ 2', () {
    test('Drive', () {
      expect(CloudNames.file(_id, gen: 2), '$_id.k2.vault');
      expect(CloudNames.thumb(_id, gen: 37), '$_id.k37.thumb');
      expect(CloudNames.recoveryBackupFor(2), 'recovery_backup.k2.json');
      expect(CloudNames.dbSnapshotFor(9999), 'vault_db.k9999.snapshot');
      expect(CloudNames.bridgeBackup(1), 'recovery_backup.bridge.k1.json');
      expect(CloudNames.quarantine(_id, 1), 'lost_$_id.k1.vault');
    });

    test('local', () {
      expect(AppPaths.vaultRelativePath(_id, gen: 2), 'vault/$_id.k2.vault');
      expect(AppPaths.thumbRelativePath(_id, gen: 3), 'thumbs/$_id.k3.thumb');
    });

    test('generación fuera de rango lanza', () {
      for (final g in [0, -1, 10000]) {
        expect(() => CloudNames.file(_id, gen: g), throwsArgumentError);
        expect(
          () => AppPaths.vaultRelativePath(_id, gen: g),
          throwsArgumentError,
        );
        expect(() => CloudNames.bridgeBackup(g), throwsArgumentError);
      }
    });
  });

  group('parse', () {
    test('ida y vuelta de todos los tipos', () {
      for (final gen in [1, 2, 10, 9999]) {
        expect(
          CloudNames.parse(CloudNames.file(_id, gen: gen)),
          CloudNameInfo(CloudNameKind.file, gen, itemId: _id),
        );
        expect(
          CloudNames.parse(CloudNames.thumb(_id, gen: gen)),
          CloudNameInfo(CloudNameKind.thumb, gen, itemId: _id),
        );
        expect(
          CloudNames.parse(CloudNames.recoveryBackupFor(gen)),
          CloudNameInfo(CloudNameKind.recoveryBackup, gen),
        );
        expect(
          CloudNames.parse(CloudNames.dbSnapshotFor(gen)),
          CloudNameInfo(CloudNameKind.dbSnapshot, gen),
        );
        expect(
          CloudNames.parse(CloudNames.bridgeBackup(gen)),
          CloudNameInfo(CloudNameKind.bridgeBackup, gen),
        );
        expect(
          CloudNames.parse(CloudNames.quarantine(_id, gen)),
          CloudNameInfo(CloudNameKind.quarantine, gen, itemId: _id),
        );
      }
    });

    for (final bad in [
      '',
      'foto.jpg',
      'vault/$_id.vault',
      '$_id.k1.vault', // la gen 1 no lleva sufijo
      '$_id.k0.vault',
      '$_id.k02.vault', // ceros a la izquierda
      '$_id.k10000.vault',
      '$_id.K2.vault',
      '$_id.k2.vault.part',
      '$_id.k2.k3.vault',
      '${_id.toUpperCase()}.vault',
      '3f2b8c1e-9d4a-1b6f-8a7c-1e2d3c4b5a69.vault', // no v4
      'i1.vault', // ids no UUID fuera de las pruebas
      '../$_id.vault',
      '$_id.vault ',
      'recovery_backup.k1.json',
      'recovery_backup.k02.json',
      'recovery_backup.bridge.json',
      'recovery_backup.bridge.k0.json',
      'vault_db.k1.snapshot',
      'vault_db.snapshot.part',
      'lost_$_id.vault', // la cuarentena siempre lleva generación
      'lost_$_id.k1.thumb',
      'lost_i1.k1.vault',
    ]) {
      test('rechaza "$bad"', () => expect(CloudNames.parse(bad), isNull));
    }
  });
}
