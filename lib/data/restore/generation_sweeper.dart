import 'dart:convert';

import '../../core/logging/vault_log.dart';
import '../cloud/cloud_names.dart';
import '../cloud/cloud_storage.dart';
import '../sync/sync_service.dart' show md5OfBytes;

/// Resultado de [GenerationSweeper.sweep].
enum SweepResult {
  /// Se borró todo lo de generaciones anteriores (o no había nada).
  done,

  /// La guarda no se cumplió (el conjunto de la generación vigente no está
  /// completo en Drive o no es el de este teléfono): no se borró NADA.
  guardFailed,
}

/// Barrido de generaciones VIEJAS en Drive (D61, §7): un teléfono en la
/// generación `G` (p. ej. recién restaurado con el código nuevo) borra los
/// nombres de Vault de generaciones `< G`. Cubre el caso de que el teléfono
/// original se perdiera tras el corte sin terminar la limpieza: así el
/// código viejo deja de abrir nada.
///
/// * Guarda: SOLO si en Drive está completo el conjunto de `G` y es el de
///   este teléfono: `recovery_backup.kG.json` con el MISMO contenido que el
///   respaldo local y `vault_db.kG.snapshot`. Si no, no borra nada.
/// * Por LISTA y en orden: respaldos (incluidos los puente) primero, luego
///   snapshots, luego blobs. Así, a mitad, el código viejo nunca abre un
///   conjunto a medias.
/// * NUNCA borra generaciones mayores (otra rama) ni la cuarentena `lost_*`
///   (M6), ni nada que no sea un nombre de Vault.
class GenerationSweeper {
  GenerationSweeper({required this.cloud});

  final CloudStorage cloud;

  /// M11 (limpieza manual, D73): nombres `.kN` con `N > currentGen` cuya
  /// generación NO tiene `recovery_backup.kN.json` (sin respaldo nadie puede
  /// restaurar con ella: es el resto de una rotación interrumpida y
  /// cancelada o de otra rama abandonada). Nunca incluye la cuarentena
  /// `lost_*`, ni nada de generaciones `<= currentGen`, ni nombres ajenos a
  /// Vault. Solo lee la lista.
  Future<List<CloudFile>> findAbandoned({required int currentGen}) async {
    final all = await cloud.list();
    final withBackup = <int>{
      for (final f in all)
        if (CloudNames.parse(f.name)?.kind == CloudNameKind.recoveryBackup)
          CloudNames.parse(f.name)!.gen,
    };
    return [
      for (final f in all)
        if (_isAbandoned(CloudNames.parse(f.name), currentGen, withBackup)) f,
    ];
  }

  static bool _isAbandoned(CloudNameInfo? i, int currentGen, Set<int> backed) =>
      i != null &&
      i.kind != CloudNameKind.quarantine &&
      i.kind != CloudNameKind.recoveryBackup &&
      i.kind != CloudNameKind.bridgeBackup &&
      i.gen > currentGen &&
      !backed.contains(i.gen);

  /// Generaciones anteriores a [currentGen] que [sweep] borraría (sin la
  /// guarda; para la vista previa de la limpieza manual).
  Future<List<CloudFile>> findStale({required int currentGen}) async {
    return [
      for (final f in await cloud.list())
        if (_isStale(CloudNames.parse(f.name), currentGen)) f,
    ];
  }

  static bool _isStale(CloudNameInfo? i, int currentGen) =>
      i != null && i.kind != CloudNameKind.quarantine && i.gen < currentGen;

  /// Borra [findAbandoned] (permanente). Devuelve cuántos archivos.
  Future<int> sweepAbandoned({required int currentGen}) async {
    final victims = await findAbandoned(currentGen: currentGen);
    var n = 0;
    for (final f in victims) {
      try {
        await cloud.delete(f.id);
        n++;
      } on CloudNotFoundException {
        // ya no estaba
      }
    }
    VaultLog.d('Limpieza de generaciones abandonadas: $n', category: 'sync');
    return n;
  }

  Future<SweepResult> sweep({
    required int currentGen,
    required String localRecoveryBackupJson,
  }) async {
    final all = await cloud.list();
    final backupName = CloudNames.recoveryBackupFor(currentGen);
    final ours = [
      for (final f in all)
        if (f.name == backupName) f,
    ];
    final hasSnapshot = all.any(
      (f) => f.name == CloudNames.dbSnapshotFor(currentGen),
    );
    final localMd5 = md5OfBytes(utf8.encode(localRecoveryBackupJson));
    final matches = ours.any((f) => f.md5Checksum?.toLowerCase() == localMd5);
    if (!hasSnapshot || !matches) {
      VaultLog.d(
        'Barrido de generaciones: guarda no cumplida',
        category: 'sync',
      );
      return SweepResult.guardFailed;
    }

    int rank(CloudNameKind k) => switch (k) {
      CloudNameKind.recoveryBackup || CloudNameKind.bridgeBackup => 0,
      CloudNameKind.dbSnapshot => 1,
      _ => 2,
    };
    final victims = <(int, CloudFile)>[];
    for (final f in all) {
      final info = CloudNames.parse(f.name);
      if (info == null || info.kind == CloudNameKind.quarantine) continue;
      // Un puente de la generación F abre F; se borra si F < G (es decir, si
      // la rotación que lo creó llegó a G o más).
      if (info.gen < currentGen) victims.add((rank(info.kind), f));
    }
    victims.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, f) in victims) {
      try {
        await cloud.delete(f.id);
      } on CloudNotFoundException {
        // ya no estaba
      }
    }
    VaultLog.d(
      'Barrido de generaciones: ${victims.length} archivos',
      category: 'sync',
    );
    return SweepResult.done;
  }
}
