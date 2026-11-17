import 'dart:async';

import '../../../core/logging/vault_log.dart';
import '../../../data/models/vault_item_model.dart';
import '../../../data/trash/trash_repository.dart';
import '../models/browser_entry.dart';
import '../vault_services.dart';

/// Días que un elemento permanece en la papelera antes de eliminarse solo.
const int kTrashRetentionDays = 30;

/// Papelera (v2 fase 5).
///
/// * [trash]: marca filas; NO toca archivos locales ni Drive (se puede
///   restaurar sin perder nada).
/// * [deleteForever] y [purgeExpired]: ahí SÍ se borra: filas, archivos
///   locales y la copia de Drive (se encola `delete_remote`), en el mismo
///   orden que el borrado directo anterior (ids de Drive leídos ANTES de
///   borrar la fila).
class TrashService {
  TrashService({
    required TrashRepository repository,
    required FileCleaner fileCleaner,
    RemoteDeleter? remoteDeleter,
    int Function()? nowMs,
    this.retentionDays = kTrashRetentionDays,
  }) : _repo = repository,
       _cleaner = fileCleaner,
       _remote = remoteDeleter,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final TrashRepository _repo;
  final FileCleaner _cleaner;
  final RemoteDeleter? _remote;
  final int Function() _now;
  final int retentionDays;

  Duration get retention => Duration(days: retentionDays);

  /// Manda las entradas a la papelera.
  Future<void> trash(Iterable<BrowserEntry> targets) async {
    final now = _now();
    for (final e in targets) {
      switch (e) {
        case FileEntry():
          await _repo.trashItem(e.item.id, now: now);
        case FolderEntry():
          await _repo.trashFolder(e.folder.id, now: now);
      }
    }
  }

  Future<List<TrashEntry>> list() => _repo.list();

  Future<int> count() => _repo.count();

  /// Días que le quedan (mínimo 0) a una entrada.
  int daysLeft(TrashEntry e) {
    final expires = e.deletedAt + retention.inMilliseconds;
    final left = expires - _now();
    if (left <= 0) return 0;
    return (left / Duration.millisecondsPerDay).ceil();
  }

  Future<bool> restore(String rootId) => _repo.restore(rootId);

  /// Elimina definitivamente las raíces dadas. Devuelve cuántos archivos se
  /// eliminaron.
  Future<int> deleteForever(Iterable<String> rootIds) async {
    final itemIds = <String>[];
    final remote = <RemoteDeleteTarget>[];
    for (final root in rootIds) {
      final items = await _repo.itemsOf(root);
      remote.addAll(items.map(_targetOf));
      itemIds.addAll(await _repo.deleteRows(root));
    }
    await _cleaner(itemIds);
    // Después de limpiar la cola local (que quita subidas del item).
    await _remote?.call(remote);
    return itemIds.length;
  }

  /// Vacía lo que lleva [retentionDays] días o más. Idempotente; pensado para
  /// el arranque/desbloqueo. Nunca lanza.
  Future<int> purgeExpired() async {
    try {
      final cutoff = _now() - retention.inMilliseconds;
      final roots = await _repo.expiredRoots(cutoff);
      if (roots.isEmpty) return 0;
      final n = await deleteForever(roots);
      VaultLog.d('Papelera vaciada: $n archivos vencidos', category: 'trash');
      return n;
    } on Object catch (e) {
      VaultLog.e('Vaciado de la papelera falló', e);
      return 0;
    }
  }

  /// Vacía toda la papelera.
  Future<int> emptyAll() async =>
      deleteForever([for (final e in await _repo.list()) e.id]);

  RemoteDeleteTarget _targetOf(VaultItemModel i) => RemoteDeleteTarget(
    i.id,
    driveFileId: i.driveFileId,
    thumbDriveFileId: i.thumbDriveFileId,
  );
}
