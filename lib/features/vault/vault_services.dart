import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import '../../core/crypto/secure_kv_store.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/vault_session.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/gallery/import_preferences.dart';
import '../../data/gallery/photo_manager_gallery_source.dart';
import '../../data/gallery/video_compress_plugin.dart';
import '../../data/models/vault_item_model.dart';
import '../../data/repositories/vault_data_repository.dart';
import '../../data/services/sync_queue_service.dart';
import '../../data/services/vault_import_service.dart';
import '../gallery/gallery_deps.dart';
import 'services/thumbnail_loader.dart';
import 'services/vault_preferences_service.dart';
import 'services/vault_viewer_service.dart';

/// Carga la miniatura descifrada de un item (`null` si no hay).
typedef ThumbnailLoader = Future<ImageProvider?> Function(VaultItemModel item);

/// Descifra/obtiene el archivo plano para el visor.
typedef MediaLoader = Future<File?> Function(VaultItemModel item);

/// Importa un archivo con el selector del sistema. `true` si se importó.
typedef FileImporter =
    Future<bool> Function({
      required String? folderId,
      required bool deleteOriginal,
    });

/// Borra del disco los archivos locales de los items (`vault/<id>.vault`,
/// `thumbs/<id>.thumb`).
typedef FileCleaner = Future<void> Function(Iterable<String> itemIds);

/// Marca/desmarca un item como disponible sin conexión.
typedef OfflineToggler = Future<bool> Function(String itemId, bool makeOffline);

/// Dependencias de la UI de la bóveda, inyectables en pruebas.
class VaultServices {
  const VaultServices({
    required this.repository,
    required this.importFile,
    required this.syncRunner,
    required this.thumbnailLoader,
    required this.mediaLoader,
    required this.fileCleaner,
    required this.offlineToggler,
    this.gallery,
  });

  final VaultDataRepository repository;
  final FileImporter importFile;

  /// Dispara la sincronización (pull-to-refresh).
  final Future<void> Function() syncRunner;
  final ThumbnailLoader thumbnailLoader;
  final MediaLoader mediaLoader;
  final FileCleaner fileCleaner;
  final OfflineToggler offlineToggler;

  /// Importación desde galería (`null` = no disponible).
  final GalleryDeps? gallery;

  /// Servicios reales. Las dependencias pesadas se crean bajo demanda.
  factory VaultServices.real() {
    _sharedThumbs ??= _createThumbs();
    final thumbs = _sharedThumbs!;
    final repository = VaultDataRepository();
    final importer = VaultImportService();
    final sync = SyncQueueService();
    return VaultServices(
      repository: repository,
      importFile: ({required folderId, required deleteOriginal}) =>
          importer.importAndEncryptFile(
            targetFolderId: folderId,
            deleteOriginal: deleteOriginal,
          ),
      syncRunner: sync.processSyncQueue,
      // Miniaturas: descifra thumbs/<id>.thumb con la subllave "thumbs" (LRU).
      thumbnailLoader: thumbs.call,
      // TODO(F6): lectura por rangos y caché cifrada.
      mediaLoader: (item) async {
        final key = VaultSession().filesKey;
        final driveId = item.driveFileId;
        if (key == null || driveId == null) return null;
        return VaultViewerService().getPlainFileForViewing(
          cloudId: driveId,
          fileName: item.name,
          secretKey: key,
        );
      },
      fileCleaner: (ids) async {
        await AppPaths.init();
        for (final id in ids) {
          for (final rel in [
            AppPaths.vaultRelativePath(id),
            AppPaths.thumbRelativePath(id),
          ]) {
            try {
              final file = AppPaths.resolve(rel);
              if (await file.exists()) await file.delete();
            } on FileSystemException {
              // Se reintentará en la limpieza de huérfanos (F5).
            }
          }
        }
        // TODO(F5): borrar también la copia en Drive.
      },
      offlineToggler: (id, makeOffline) =>
          VaultPreferenceService().toggleOfflineMode(id, makeOffline),
      gallery: _sharedGallery ??= _createGallery(repository),
    );
  }

  static EncryptedThumbnailLoader? _sharedThumbs;
  static GalleryDeps? _sharedGallery;

  static EncryptedThumbnailLoader _createThumbs() {
    final session = VaultSession();
    final loader = EncryptedThumbnailLoader(
      thumbsKey: () => session.keysOrNull?.thumbs,
    );
    // Al bloquear, la caché en memoria se vacía.
    session.addOnClear(loader.clear);
    return loader;
  }

  static GalleryDeps _createGallery(VaultDataRepository repository) {
    final session = VaultSession();
    final source = PhotoManagerGallerySource();
    final service = GalleryImportService(
      source: source,
      compressor: VideoCompressPlugin(),
      repository: repository,
      filesKey: () => session.filesKey,
      thumbsKey: () => session.keysOrNull?.thumbs,
      tempDirProvider: () =>
          Directory(p.join(AppPaths.cacheDir.path, 'import_tmp')),
      // Borrado de originales apagado hasta que F5 verifique la copia en la
      // nube (cloudVerifier). Ver GalleryImportService.
    );
    return GalleryDeps(
      source: source,
      service: service,
      preferences: GalleryImportPreferences(FlutterSecureKeyValueStore()),
    );
  }
}
