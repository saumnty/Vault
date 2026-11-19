import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/vault_log.dart';
import '../../data/gallery/gallery_album_source.dart';
import '../../data/gallery/import_queue_service.dart';
import '../../data/models/folder_model.dart';
import '../../data/repositories/vault_data_repository.dart';
import '../../shared/navigation/app_page_route.dart';
import 'gallery_deps.dart';
import 'gallery_import_screen.dart';
import 'gallery_picker_screen.dart';
import 'import_options_sheet.dart';
import 'import_queue_sheet.dart';

/// «Importar de galería» con la cola reanudable (v2.2, D86): pestañas Fotos
/// | Álbumes → calidad de video → destino (álbum: carpeta con su nombre por
/// defecto) → encolar y estimar → aviso de espacio/datos → empezar → hoja de
/// progreso. Si ya hay un lote sin cerrar, abre su hoja en lugar de empezar
/// otro. Devuelve `true` si se mostró la hoja de la cola (hubo trabajo).
Future<bool> runGalleryQueueImport(
  BuildContext context, {
  required GalleryDeps gallery,
  required ImportQueueService queue,
  required GalleryAlbumSource source,
  required VaultDataRepository repository,
  required String? currentFolderId,
  required String currentFolderName,
}) async {
  try {
    final open = await queue.refresh();
    if (open != null) {
      if (!context.mounted) return false;
      await openImportQueueSheet(context, queue: queue, gallery: gallery);
      return true;
    }
  } on Object {
    // sin lote legible: se sigue con uno nuevo
  }
  if (!context.mounted) return false;
  final picked = await Navigator.of(context).push<GalleryPickResult>(
    AppPageRoute<GalleryPickResult>(
      builder: (_) => GalleryImportScreen(source: source),
    ),
  );
  if (picked == null || picked.count <= 0 || !context.mounted) return false;
  final prefDelete = await gallery.preferences.getDeleteOriginalsWhenInCloud();
  final prefQuality = await gallery.preferences.getVideoQuality();
  if (!context.mounted) return false;
  final choices = await showImportOptionsSheet(
    context,
    assets: picked.allSelected ? const [] : picked.assets,
    albumCount: picked.allSelected ? picked.count : null,
    deleteOriginalsWhenInCloud: prefDelete,
    initialQuality: prefQuality,
  );
  if (choices == null || !context.mounted) return false;
  await gallery.preferences.setDeleteOriginalsWhenInCloud(
    choices.deleteOriginalsWhenInCloud,
  );

  // Destino: un álbum elegido en «Álbumes» va por defecto a una carpeta con
  // su nombre (dentro de la carpeta actual).
  String? folderId = currentFolderId;
  String? newFolderName;
  final album = picked.album;
  if (picked.fromAlbumList && album != null) {
    final siblings = await repository.getFoldersByParent(currentFolderId);
    if (!context.mounted) return false;
    final dest = await showAlbumDestinationSheet(
      context,
      albumName: album.name.trim().isEmpty ? 'Álbum' : album.name.trim(),
      currentFolderName: currentFolderName,
      siblingNames: [for (final f in siblings) f.name],
    );
    if (dest == null || !context.mounted) return false;
    switch (dest.kind) {
      case ImportDestinationKind.existingFolder:
        final name = album.name.trim().toLowerCase();
        folderId = siblings.firstWhere((f) => f.name.toLowerCase() == name).id;
      case ImportDestinationKind.newFolder:
        newFolderName = dest.folderName;
      case ImportDestinationKind.currentFolder:
        break;
    }
  }

  // Encolar (paginado) y estimar.
  final ImportPreflight pre;
  try {
    pre = await queue.prepare(
      picked.allSelected && album != null
          ? ImportRequest.album(
              album.id,
              excluded: picked.excluded,
              videoQuality: choices.videoQuality,
            )
          : ImportRequest.assets(
              picked.assets,
              videoQuality: choices.videoQuality,
            ),
    );
  } on ImportBatchBusyException {
    if (context.mounted) {
      await openImportQueueSheet(context, queue: queue, gallery: gallery);
    }
    return true;
  } on Object catch (e) {
    VaultLog.e('No se pudo preparar la importación', e, 'import');
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('No se pudo preparar la importación')),
      );
    }
    return false;
  }
  if (!context.mounted) {
    unawaited(queue.discard(pre.batchId).catchError((_) {}));
    return false;
  }
  final go = await showImportPreflightSheet(context, preflight: pre);
  if (!go || pre.total == 0 || !context.mounted) {
    try {
      await queue.discard(pre.batchId);
    } on Object {
      // se descarta al próximo desbloqueo (`preparing`)
    }
    return false;
  }
  if (newFolderName != null) {
    final id = const Uuid().v4();
    await repository.createFolder(
      FolderModel(
        id: id,
        name: newFolderName,
        parentId: currentFolderId,
        createdAt: DateTime.now().toIso8601String(),
      ),
    );
    folderId = id;
  }
  unawaited(
    queue.start(pre.batchId, folderId: folderId).catchError((Object e) {
      VaultLog.e('Importación no iniciada', e, 'import');
    }),
  );
  if (!context.mounted) return true;
  await openImportQueueSheet(
    context,
    queue: queue,
    gallery: gallery,
    deleteOriginalsEnabled: choices.deleteOriginalsWhenInCloud,
  );
  return true;
}

/// Abre la hoja de la cola (reanudar, ver progreso o el resumen).
Future<void> openImportQueueSheet(
  BuildContext context, {
  required ImportQueueService queue,
  required GalleryDeps gallery,
  bool? deleteOriginalsEnabled,
}) async {
  final del =
      deleteOriginalsEnabled ??
      await gallery.preferences.getDeleteOriginalsWhenInCloud();
  if (!context.mounted) return;
  await showImportQueueSheet(
    context,
    service: queue,
    deleteOriginalsEnabled: del,
  );
}
