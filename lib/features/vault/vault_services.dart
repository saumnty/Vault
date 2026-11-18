import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/foundation.dart' show ValueListenable, kDebugMode;
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import '../../core/crypto/auth_controller.dart';
import '../../core/crypto/secure_kv_store.dart';
import '../../core/services/app_paths.dart';
import '../../core/services/cache_manager.dart';
import '../../core/services/plain_temp_manager.dart';
import '../../core/session/primary_gates.dart';
import '../../core/session/session_hooks.dart';
import '../../core/session/vault_session.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/gallery/import_preferences.dart';
import '../../data/gallery/photo_manager_gallery_source.dart';
import '../../data/gallery/thumbnail_regeneration_service.dart';
import '../../data/gallery/video_thumbnailer.dart';
import '../../data/gallery/video_compress_plugin.dart';
import '../../data/cloud/cloud_provider.dart';
import '../../data/migration/account_migration_service.dart';
import '../../data/migration/free_space.dart';
import '../../data/migration/migration_repository.dart';
import '../../data/repositories/vault_database.dart';
import '../../data/rotation/item_reencryptor.dart';
import '../../data/rotation/key_rotation_service.dart';
import '../../data/rotation/rotation_guard.dart';
import '../../data/rotation/rotation_repository.dart';
import '../../data/sync/network_monitor.dart';
import '../../data/sync/offline_service.dart';
import '../../data/sync/sync_preferences.dart';
import '../../data/sync/sync_queue_repository.dart';
import '../../data/sync/storage_service.dart';
import '../../data/sync/sync_service.dart';
import '../../data/sync/vault_file_fetcher.dart';
import '../../data/models/vault_item_model.dart';
import '../../data/repositories/vault_data_repository.dart';
import '../../data/services/vault_import_service.dart';
import '../gallery/gallery_deps.dart';
import 'services/thumbnail_loader.dart';
import 'services/trash_service.dart';
import '../../data/tags/tag_repository.dart';
import '../../data/trash/trash_repository.dart';
import '../../data/gallery/photo_saver.dart';
import 'viewer/media_exporter.dart';
import 'viewer/media_opener.dart';

/// Carga la miniatura descifrada de un item (`null` si no hay).
typedef ThumbnailLoader = Future<ImageProvider?> Function(VaultItemModel item);

/// Importa un archivo con el selector del sistema. `true` si se importó.
typedef FileImporter =
    Future<bool> Function({
      required String? folderId,
      required bool deleteOriginal,
    });

/// Borra del disco los archivos locales de los items (`vault/<id>.vault`,
/// `thumbs/<id>.thumb`) y sus subidas pendientes.
typedef FileCleaner = Future<void> Function(Iterable<String> itemIds);

/// Marca/desmarca un item como disponible sin conexión.
typedef OfflineToggler = Future<bool> Function(String itemId, bool makeOffline);

/// Marca/desmarca una carpeta (y todo su contenido) sin conexión.
typedef FolderOfflineToggler =
    Future<void> Function(String folderId, bool makeOffline);

/// Qué hay que borrar de Drive al eliminar un item (ids tal como estaban en
/// la BD justo antes de borrar la fila).
class RemoteDeleteTarget {
  const RemoteDeleteTarget(
    this.itemId, {
    this.driveFileId,
    this.thumbDriveFileId,
  });
  final String itemId;
  final String? driveFileId;
  final String? thumbDriveFileId;
}

/// Encola el borrado remoto de los items eliminados.
typedef RemoteDeleter = Future<void> Function(List<RemoteDeleteTarget> targets);

/// Abre medios cuando no hay servicios reales (pruebas de la cuadrícula).
class UnavailableMediaOpener implements MediaOpener {
  const UnavailableMediaOpener();

  @override
  Future<Uint8List> loadImage(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  }) => Future.error(StateError('Visor no disponible'));

  @override
  VideoSource videoSource(VaultItemModel item) =>
      throw StateError('Visor no disponible');
}

/// Dependencias de la UI de la bóveda, inyectables en pruebas.
class VaultServices {
  const VaultServices({
    required this.repository,
    required this.importFile,
    required this.syncRunner,
    required this.thumbnailLoader,
    required this.fileCleaner,
    required this.offlineToggler,
    this.mediaOpener = const UnavailableMediaOpener(),
    this.mediaExporter,
    this.trash,
    this.tags,
    this.folderOfflineToggler,
    this.remoteDeleter,
    this.downloadProgress,
    this.onUnlocked,
    this.afterOpen,
    this.beforeLock,
    this.cache,
    this.gallery,
    this.sync,
    this.storage,
    this.migration,
    this.rotation,
  });

  final VaultDataRepository repository;
  final FileImporter importFile;

  /// Dispara la sincronización (pull-to-refresh).
  final Future<void> Function() syncRunner;
  final ThumbnailLoader thumbnailLoader;
  final FileCleaner fileCleaner;
  final OfflineToggler offlineToggler;

  /// Abre fotos (en memoria) y videos (origen [VideoSource]) para el visor.
  final MediaOpener mediaOpener;

  /// "Guardar en Fotos" (`null` = no disponible).
  final MediaExporter? mediaExporter;

  /// Papelera (`null` = borrado directo, p. ej. pruebas de la cuadrícula).
  final TrashService? trash;

  /// Etiquetas y búsqueda con filtros (`null` = sin esa función).
  final TagRepository? tags;

  /// Por defecto `repository.setFolderOffline`.
  final FolderOfflineToggler? folderOfflineToggler;

  /// Encola el borrado en Drive (`null` = sin nube, p. ej. pruebas).
  final RemoteDeleter? remoteDeleter;

  /// Progreso de descargas "sin conexión" por id de item.
  final ValueListenable<Map<String, double>>? downloadProgress;

  /// Al abrir la bóveda (desbloqueo/arranque): barre temporales descifrados,
  /// reconcilia "sin conexión" y aplica el límite de la caché.
  final Future<void> Function()? onUnlocked;

  /// Tras importar: aplica el límite de la caché.
  final Future<void> Function()? afterOpen;

  /// Al bloquear (F9), ANTES de cerrar la sesión: toma la copia cifrada de la
  /// BD si hay cambios sin respaldar (la subida sigue en segundo plano).
  final Future<void> Function()? beforeLock;

  /// Caché LRU (API de límite para F8).
  final CacheManager? cache;

  /// Importación desde galería (`null` = no disponible).
  final GalleryDeps? gallery;

  /// Sincronización con la nube (`null` = no disponible, p. ej. pruebas).
  final SyncService? sync;

  /// Almacenamiento de Ajustes (límite de caché, liberar espacio). `null` =
  /// no disponible (pruebas).
  final StorageService? storage;

  /// Cambio de cuenta de Google con migración (`null` = no disponible).
  final AccountMigrationService? migration;

  /// Rotación de la llave maestra (`null` = no disponible, p. ej. pruebas).
  final KeyRotationService? rotation;

  /// `true` si son los servicios de una bóveda sin nube (la secundaria).
  bool get isCloudless => sync == null;

  /// Servicios de la bóveda SECUNDARIA (fase 8, D67, DISENO_SENUELO §4.4):
  /// instancias PROPIAS (BD `alt/db`, rutas `alt/`, llaves ligadas a la
  /// secundaria, ticket de su sesión) y nada de `_Core`: sin sincronización,
  /// nube, sin conexión, migración ni rotación. Se crean una vez por proceso
  /// (como los de la principal) y se reutilizan en cada desbloqueo de la
  /// secundaria; sus cachés y lotes se vacían/cancelan al bloquear.
  factory VaultServices.secondary() => _secondary ??= _createSecondary();

  static VaultServices? _secondary;

  static VaultServices _createSecondary() {
    const slot = VaultSlot.secondary;
    final session = VaultSession();
    SessionHooks.ensureInstalled(session);
    final paths = VaultPaths.secondary;
    final db = VaultDatabase.secondaryInstance;
    final repository = VaultDataRepository(dbProvider: () => db.database);
    SessionTicket? ticket() =>
        session.isUnlockedAs(slot) ? session.ticket() : null;
    SecretKey? filesKey() =>
        session.isUnlockedAs(slot) ? session.filesKey : null;
    SecretKey? thumbsKey() =>
        session.isUnlockedAs(slot) ? session.keysOrNull?.thumbs : null;
    final importer = VaultImportService(
      repository: repository,
      paths: paths,
      sessionTicket: ticket,
    );
    final temp = PlainTempManager(dirProvider: () => paths.tmpPlainDir);
    session.addOnClear(temp.purgeSync);
    final thumbs = EncryptedThumbnailLoader(
      thumbsKey: (gen) => session.thumbsKeyFor(gen, slot),
      refresh: repository.getItem,
      resolve: paths.resolve,
    );
    session.addOnClear(thumbs.clear);
    // La nube va con guarda (CloudSlotException): un `.vault` ausente da
    // "no disponible", nunca una descarga.
    final fetcher = VaultFileFetcher(
      cloud: CloudProvider.instance,
      items: repository,
      resolvePath: paths.resolve,
      sessionTicket: ticket,
    );
    final opener = VaultMediaOpener(
      fetcher: fetcher,
      filesKey: (gen) => session.filesKeyFor(gen, slot),
      temp: temp,
      session: session,
    );
    Future<void> cleaner(Iterable<String> ids) async {
      for (final id in ids) {
        for (final rel in [
          AppPaths.vaultRelativePath(id),
          AppPaths.thumbRelativePath(id),
        ]) {
          try {
            final file = paths.resolve(rel);
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            // se reintentará
          }
        }
      }
    }

    final trash = TrashService(
      repository: TrashRepository(dbProvider: () => db.database),
      fileCleaner: cleaner,
      sessionTicket: ticket,
    );
    final source = PhotoManagerGallerySource();
    final videoThumbnailer = PlatformVideoThumbnailer();
    final gallery = GalleryImportService(
      source: source,
      compressor: VideoCompressPlugin(),
      repository: repository,
      filesKey: filesKey,
      thumbsKey: thumbsKey,
      keyGen: () => 1,
      tempDirProvider: () => paths.importTmpDir,
      // Sin nube no hay verificación: nunca se borran originales.
      deletionEnabledProvider: () async => false,
      cloudVerifier: (_) async => false,
      videoThumbnailer: videoThumbnailer,
      paths: paths,
      sessionTicket: ticket,
    );
    final regeneration = ThumbnailRegenerationService(
      repository: repository,
      source: source,
      videoThumbnailer: videoThumbnailer,
      filesKey: (gen) => session.filesKeyFor(gen, slot),
      thumbsKey: (gen) => session.thumbsKeyFor(gen, slot),
      tempDirProvider: () => paths.importTmpDir,
      paths: paths,
      sessionTicket: ticket,
    );
    session.addOnClear(gallery.cancelRunning);
    session.addOnClear(regeneration.cancel);
    return VaultServices(
      repository: repository,
      importFile: ({required folderId, required deleteOriginal}) =>
          importer.importAndEncryptFile(targetFolderId: folderId),
      syncRunner: () async {},
      thumbnailLoader: thumbs.call,
      mediaOpener: opener,
      mediaExporter: VaultMediaExporter(
        opener: opener,
        saver: PhotoManagerPhotoSaver(),
        sessionTicket: ticket,
      ),
      fileCleaner: cleaner,
      trash: trash,
      tags: TagRepository(dbProvider: () => db.database),
      offlineToggler: (_, _) async => false,
      folderOfflineToggler: (_, _) async {},
      onUnlocked: () async {
        final t = ticket();
        if (t == null) return;
        await temp.sweep();
        if (!t.isValid) return;
        await trash.purgeExpired();
        if (!t.isValid) return;
        unawaited(regeneration.run());
      },
      gallery: GalleryDeps(
        source: source,
        service: gallery,
        preferences: GalleryImportPreferences(FlutterSecureKeyValueStore()),
        regeneration: regeneration,
      ),
    );
  }

  /// Servicios reales. Las dependencias pesadas se crean bajo demanda.
  factory VaultServices.real() {
    _sharedThumbs ??= _createThumbs();
    final thumbs = _sharedThumbs!;
    final repository = VaultDataRepository();
    final importer = VaultImportService();
    final core = _core ??= _createCore(repository);
    final sync = core.sync;
    Future<void> cleaner(Iterable<String> ids) async {
      await AppPaths.init();
      // D60: los archivos del item pueden ser de cualquier generación de llave
      // conocida por la sesión (también restos de otra durante una rotación).
      final maxGen = VaultSession().maxGen;
      for (final id in ids) {
        for (final rel in [
          for (var gen = 1; gen <= maxGen; gen++) ...[
            AppPaths.vaultRelativePath(id, gen: gen),
            AppPaths.thumbRelativePath(id, gen: gen),
          ],
        ]) {
          try {
            final file = AppPaths.resolve(rel);
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            // Se reintentará en la limpieza de huérfanos.
          }
        }
        try {
          // Quita subidas pendientes del item (NO sus borrados remotos).
          await sync.queue.removeForItem(id);
        } on StateError {
          // bloqueada
        }
      }
    }

    Future<void> remoteDeleter(List<RemoteDeleteTarget> targets) async {
      for (final t in targets) {
        await sync.enqueueRemoteDelete(
          t.itemId,
          driveFileId: t.driveFileId,
          thumbDriveFileId: t.thumbDriveFileId,
        );
      }
      unawaited(sync.run(manual: true));
    }

    final trash = TrashService(
      repository: TrashRepository(),
      fileCleaner: cleaner,
      remoteDeleter: remoteDeleter,
      // D67: el borrado definitivo es de la sesión principal que lo empezó.
      sessionTicket: PrimaryGates.ticket(VaultSession()),
    );
    return VaultServices(
      repository: repository,
      importFile: ({required folderId, required deleteOriginal}) =>
          importer.importAndEncryptFile(
            targetFolderId: folderId,
            deleteOriginal: deleteOriginal,
          ),
      syncRunner: () => sync.run(manual: true),
      // Miniaturas: descifra thumbs/<id>.thumb con la subllave "thumbs" (LRU).
      thumbnailLoader: thumbs.call,
      mediaOpener: core.opener,
      mediaExporter: VaultMediaExporter(
        opener: core.opener,
        saver: PhotoManagerPhotoSaver(),
        sessionTicket: PrimaryGates.ticket(VaultSession()),
      ),
      fileCleaner: cleaner,
      remoteDeleter: remoteDeleter,
      trash: trash,
      tags: TagRepository(),
      offlineToggler: core.offline.setItemOffline,
      folderOfflineToggler: core.offline.setFolderOffline,
      downloadProgress: core.offline.progress,
      cache: core.cache,
      afterOpen: () async {
        await core.cache.enforce();
      },
      beforeLock: sync.flushSnapshotBeforeLock,
      onUnlocked: () async {
        // D67: solo con la principal abierta y mientras siga siéndolo (un
        // bloqueo o la otra bóveda a mitad cortan el resto).
        final session = VaultSession();
        if (!session.isUnlockedAs(VaultSlot.primary)) return;
        final t = session.ticket();
        await core.temp.sweep();
        if (!t.isValid) return;
        // Papelera: lo que lleva 30 días o más se elimina (y su copia de Drive).
        await trash.purgeExpired();
        if (!t.isValid) return;
        await core.offline.reconcile();
        if (!t.isValid) return;
        await core.cache.enforce();
        if (!t.isValid) return;
        // Miniaturas que faltan (p. ej. videos importados sin miniatura):
        // en segundo plano, acotado y sin bloquear la apertura.
        final regen = _sharedGallery?.regeneration;
        if (regen != null) unawaited(regen.run());
        // Cambio de cuenta a medias (app matada, bloqueo): se retoma solo
        // si no necesita al usuario.
        final m = core.migration;
        final st = await m.refresh();
        if (!t.isValid) return;
        if (st != null && _autoResumable(st.phase)) unawaited(m.resume());
        // Rotación de la DEK a medias: se retoma sola salvo que espere al
        // usuario (código sin confirmar o un bloqueo).
        final rot = await RotationKeyStore.shared.load();
        if (!t.isValid) return;
        if (rot != null &&
            !rot.phase.isBlocked &&
            rot.phase != RotationPhase.prepared) {
          unawaited(core.rotation.resume());
        }
      },
      gallery: _sharedGallery ??= _createGallery(repository, sync),
      sync: sync,
      storage: StorageService(
        cache: core.cache,
        items: repository,
        offline: core.offline,
      ),
      migration: core.migration,
      rotation: core.rotation,
    );
  }

  static _Core? _core;

  static _Core _createCore(VaultDataRepository repository) {
    final session = VaultSession();
    final cloud = CloudProvider.instance;
    final prefsStore = FlutterSecureKeyValueStore();
    final cache = CacheManager(
      repository: repository,
      preferences: CachePreferences(prefsStore),
      // D67: solo purga la principal y para si la sesión cambia.
      sessionTicket: PrimaryGates.ticket(session),
    );
    // Depuración: `--dart-define=VAULT_CACHE_LIMIT=<bytes>` fija el límite de
    // la caché (solo en builds de depuración; F8 traerá el ajuste de usuario).
    const debugLimit = String.fromEnvironment('VAULT_CACHE_LIMIT');
    if (kDebugMode && debugLimit.isNotEmpty) {
      final v = int.tryParse(debugLimit);
      if (v != null) unawaited(CachePreferences(prefsStore).setLimitBytes(v));
    }
    final sync = _createSync(repository, cache.enforce);
    // F9: todo cambio de datos marca el snapshot como sucio (con debounce).
    // D67: solo los cambios de la PRINCIPAL (la secundaria nunca marca sucio
    // el snapshot de Drive).
    VaultDataRepository.onDataChanged = PrimaryGates.dataChanged(
      session,
      sync.notifyDataChanged,
    );
    final fetcher = VaultFileFetcher(
      cloud: cloud,
      items: repository,
      resolvePath: AppPaths.resolve,
      sessionTicket: PrimaryGates.ticket(session),
    );
    final temp = PlainTempManager.instance;
    // Al bloquear: registro de diagnóstico en memoria, temporales descifrados
    // (de las dos bóvedas, sin esperas), servidores de streaming locales y
    // caché de imágenes. Ganchos COMUNES a las dos bóvedas (D67).
    SessionHooks.ensureInstalled(session);
    final offline = OfflineService(
      items: repository,
      fetcher: fetcher,
      network: ConnectivityPlusMonitor(),
      prefs: SyncPreferences(prefsStore),
      // D67: solo con la principal abierta.
      isUnlocked: PrimaryGates.unlocked(session),
      sessionTicket: PrimaryGates.ticket(session),
    )..start();
    session.addOnClear(offline.cancel);
    final opener = VaultMediaOpener(
      fetcher: fetcher,
      // D60: la llave de la generación del item que se abre; D67: solo de la
      // bóveda principal (con la secundaria abierta, `null`).
      filesKey: (gen) => session.filesKeyFor(gen, VaultSlot.primary),
      temp: temp,
      session: session,
      markInUse: cache.markInUse,
      releaseInUse: cache.releaseInUse,
      onOpened: () async {
        await cache.enforce();
      },
    );
    final migration = AccountMigrationService(
      cloud: cloud,
      items: repository,
      migration: MigrationRepository(),
      queue: sync.queue,
      sync: sync,
      fetcher: fetcher,
      network: ConnectivityPlusMonitor(),
      prefs: SyncPreferences(prefsStore),
      recoveryBackupProvider: () => AuthController().exportRecoveryBackup(),
      resolvePath: AppPaths.resolve,
      setCachePurgeSuspended: (v) => cache.suspended = v,
      // D61: cambio de cuenta y rotación de la DEK son excluyentes.
      rotationActive: () async =>
          (await RotationKeyStore.shared.load()) != null,
      // D67: solo con la principal abierta; para si la sesión cambia.
      sessionTicket: PrimaryGates.ticket(session),
      freeSpace: platformFreeSpace,
    );
    // Al bloquear: el cambio de cuenta se pausa (el estado queda en la BD).
    session.addOnClear(migration.pause);
    // Rotación de la DEK (S-11, DISENO_ROTACION.md). Usa el almacén de
    // rotación compartido (`RotationKeyStore.shared`): ve la DEK nueva que
    // dejó en memoria el desbloqueo con PIN.
    final rotation = KeyRotationService(
      auth: AuthController(),
      session: session,
      db: VaultDatabase.instance,
      items: repository,
      queue: sync.queue,
      sync: sync,
      cloud: cloud,
      network: ConnectivityPlusMonitor(),
      prefs: SyncPreferences(prefsStore),
      repo: RotationRepository(),
      reencryptor: ItemReencryptor(
        items: repository,
        cloud: cloud,
        workDir: () => Directory(p.join(AppPaths.cacheDir.path, 'rotation')),
        isInUse: cache.isInUse,
      ),
      isInUse: cache.isInUse,
      migrationActive: migration.hasActive,
    );
    // Al bloquear: la rotación se pausa (su estado está en disco).
    session.addOnClear(rotation.pause);
    // Antes del corte no se purgan los `.vault` de la generación vieja aún
    // por re-cifrar (habría que volver a bajarlos).
    cache.protectedKeyGen = () {
      final r = RotationKeyStore.shared.record.value;
      return r != null && r.freezeMeta ? r.fromGen : null;
    };
    return _Core(
      sync,
      cache,
      fetcher,
      offline,
      opener,
      temp,
      migration,
      rotation,
    );
  }

  /// Fases que se retoman solas (las demás esperan una decisión).
  static bool _autoResumable(MigrationPhase p) =>
      p == MigrationPhase.downloading ||
      p == MigrationPhase.checkingNew ||
      p == MigrationPhase.uploading ||
      p == MigrationPhase.finalizing;

  static SyncService _createSync(
    VaultDataRepository repository,
    Future<List<String>> Function() enforceCache,
  ) {
    final session = VaultSession();
    final sync = SyncService(
      cloud: CloudProvider.instance,
      queue: SyncQueueRepository(),
      items: repository,
      network: ConnectivityPlusMonitor(),
      prefs: SyncPreferences(FlutterSecureKeyValueStore()),
      // D67: la sincronización es solo de la principal (con la secundaria
      // abierta no corre ninguna pasada).
      isUnlocked: PrimaryGates.unlocked(session),
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: () => AuthController().exportRecoveryBackup(),
      snapshotProvider: () => VaultDatabase.instance.exportEncryptedSnapshot(),
      // Tras subir, aplica el límite de la caché.
      afterRun: () async {
        await enforceCache();
      },
      // D60/D61: generación vigente (nombre del respaldo) y rotación en curso.
      rotation: StoreRotationGuard(RotationKeyStore.shared),
      currentKeyGen: () => AuthController().currentKeyGen(),
    );
    // Al bloquear: cancela la subida en curso y los reintentos programados.
    session.addOnClear(sync.cancel);
    unawaited(sync.start());
    return sync;
  }

  static EncryptedThumbnailLoader? _sharedThumbs;
  static GalleryDeps? _sharedGallery;

  static EncryptedThumbnailLoader _createThumbs() {
    final session = VaultSession();
    final repository = VaultDataRepository();
    final loader = EncryptedThumbnailLoader(
      // D60: la llave de la generación del item (D67: de la principal).
      thumbsKey: (gen) => session.thumbsKeyFor(gen, VaultSlot.primary),
      refresh: repository.getItem,
    );
    // Al bloquear, la caché en memoria se vacía.
    session.addOnClear(loader.clear);
    // S-05: y la caché global de imágenes decodificadas de Flutter (gancho
    // común, D67).
    SessionHooks.ensureInstalled(session);
    return loader;
  }

  static GalleryDeps _createGallery(
    VaultDataRepository repository,
    SyncService sync,
  ) {
    final session = VaultSession();
    final source = PhotoManagerGallerySource();
    final preferences = GalleryImportPreferences(FlutterSecureKeyValueStore());
    final videoThumbnailer = PlatformVideoThumbnailer();
    final service = GalleryImportService(
      source: source,
      compressor: VideoCompressPlugin(),
      repository: repository,
      // D67: llaves de la sesión PRINCIPAL (la secundaria tendrá su propia
      // instancia); con la secundaria abierta, `null` = no importa.
      filesKey: () =>
          session.isUnlockedAs(VaultSlot.primary) ? session.filesKey : null,
      thumbsKey: () => session.isUnlockedAs(VaultSlot.primary)
          ? session.keysOrNull?.thumbs
          : null,
      keyGen: () => session.currentGen,
      sessionTicket: PrimaryGates.ticket(session),
      tempDirProvider: () =>
          Directory(p.join(AppPaths.cacheDir.path, 'import_tmp')),
      // F5: verificador real (en_nube + driveFileId + MD5/tamaño). La bandera
      // maestra sigue APAGADA: el borrado de originales exige además la
      // confirmación explícita del usuario y la preferencia (apagada por
      // defecto, leída en cada intento). No se borra nada automáticamente.
      deletionEnabledProvider: preferences.getDeleteOriginalsWhenInCloud,
      cloudVerifier: sync.cloudVerifier,
      // A1 (D61): sin borrar originales mientras se rota la llave.
      originalsDeletionPaused: () => sync.rotation.active,
      videoThumbnailer: videoThumbnailer,
    );
    final regeneration = ThumbnailRegenerationService(
      repository: repository,
      source: source,
      videoThumbnailer: videoThumbnailer,
      // D60: la miniatura se escribe con la generación de su item.
      filesKey: (gen) => session.filesKeyFor(gen, VaultSlot.primary),
      thumbsKey: (gen) => session.thumbsKeyFor(gen, VaultSlot.primary),
      // D61: en pausa mientras se rota la llave.
      paused: () => sync.rotation.active,
      tempDirProvider: () =>
          Directory(p.join(AppPaths.cacheDir.path, 'import_tmp')),
      sessionTicket: PrimaryGates.ticket(session),
    );
    // D67: al bloquear se cancelan el lote de importación y la regeneración.
    session.addOnClear(service.cancelRunning);
    session.addOnClear(regeneration.cancel);
    return GalleryDeps(
      source: source,
      service: service,
      preferences: preferences,
      regeneration: regeneration,
    );
  }
}

/// Servicios reales compartidos (una sola instancia por proceso).
class _Core {
  _Core(
    this.sync,
    this.cache,
    this.fetcher,
    this.offline,
    this.opener,
    this.temp,
    this.migration,
    this.rotation,
  );

  final SyncService sync;
  final CacheManager cache;
  final VaultFileFetcher fetcher;
  final OfflineService offline;
  final VaultMediaOpener opener;
  final PlainTempManager temp;
  final AccountMigrationService migration;
  final KeyRotationService rotation;
}
