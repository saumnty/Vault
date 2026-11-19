import '../../core/security/auto_lock.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'gallery_album_source.dart';
import 'gallery_asset_source.dart';

/// Implementación real sobre `photo_manager` 3.12.0.
///
/// Probado en el emulador Android (F4); álbumes y búsqueda por id (v2.2,
/// D86) escritos contra la API de 3.12.0 leída en su fuente. iOS (iCloud,
/// álbumes inteligentes): sin probar.
class PhotoManagerGallerySource implements GalleryAlbumSource {
  AssetPathEntity? _all;

  /// Álbumes ya listados (por id): evita `AssetPathEntity.fromId` al paginar.
  final Map<String, AssetPathEntity> _albums = {};

  static FilterOptionGroup _filter() => FilterOptionGroup(
    orders: [const OrderOption(type: OrderOptionType.createDate)],
  );

  @override
  Future<GalleryPermission> requestPermission() async {
    final state = await AutoLockSuspension.instance.run(
      PhotoManager.requestPermissionExtend,
    );
    if (state == PermissionState.authorized) return GalleryPermission.granted;
    if (state == PermissionState.limited) return GalleryPermission.limited;
    return GalleryPermission.denied;
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  Future<AssetPathEntity?> _allPath() async {
    if (_all != null) return _all;
    final paths = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.common,
      filterOption: _filter(),
    );
    return _all = paths.isEmpty ? null : paths.first;
  }

  @override
  Future<int> assetCount() async => (await _allPath())?.assetCountAsync ?? 0;

  static GalleryAsset? _toAsset(AssetEntity a) {
    if (a.type != AssetType.image && a.type != AssetType.video) return null;
    return GalleryAsset(
      id: a.id,
      type: a.type == AssetType.video
          ? GalleryAssetType.video
          : GalleryAssetType.image,
      title: a.title,
      duration: Duration(seconds: a.duration),
      width: a.width,
      height: a.height,
      createdAt: a.createDateTime,
    );
  }

  static List<GalleryAsset> _toAssets(List<AssetEntity> list) => [
    for (final a in list) ?_toAsset(a),
  ];

  @override
  Future<List<GalleryAsset>> listAssets({
    required int page,
    required int size,
  }) async {
    final path = await _allPath();
    if (path == null) return const [];
    return _toAssets(await path.getAssetListPaged(page: page, size: size));
  }

  // ------------------------------------------------------------ álbumes

  @override
  Future<List<GalleryAlbum>> listAlbums() async {
    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      type: RequestType.common,
      filterOption: _filter(),
    );
    final out = <GalleryAlbum>[];
    _albums.clear();
    for (final p in paths) {
      // iOS: `albumType == 2` son carpetas de álbumes (sin assets propios).
      if (p.albumType != 1) continue;
      final count = await p.assetCountAsync;
      if (count == 0 && !p.isAll) continue;
      _albums[p.id] = p;
      if (p.isAll) _all = p;
      out.add(GalleryAlbum(id: p.id, name: p.name, count: count, isAll: p.isAll));
    }
    out.sort((a, b) {
      if (a.isAll != b.isAll) return a.isAll ? -1 : 1;
      return 0; // el resto en el orden del sistema
    });
    return out;
  }

  Future<AssetPathEntity> _album(String id) async =>
      _albums[id] ??= await AssetPathEntity.fromId(
        id,
        filterOption: _filter(),
        type: RequestType.common,
      );

  @override
  Future<List<GalleryAsset>> listAlbumAssets(
    String albumId, {
    required int page,
    required int size,
  }) async {
    final path = await _album(albumId);
    return _toAssets(await path.getAssetListPaged(page: page, size: size));
  }

  @override
  Future<GalleryAsset?> assetById(String id) async {
    final a = await AssetEntity.fromId(id);
    return a == null ? null : _toAsset(a);
  }

  // ------------------------------------------------------------ archivos

  @override
  Future<bool> isLocallyAvailable(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    if (asset == null) return false;
    return asset.isLocallyAvailable(isOrigin: true);
  }

  @override
  Future<OriginFile?> originFile(
    String assetId, {
    bool allowNetwork = false,
    void Function(double progress)? onProgress,
  }) async {
    final asset = await AssetEntity.fromId(assetId);
    if (asset == null) return null;
    PMProgressHandler? handler;
    // iOS: la descarga desde iCloud solo existe en iOS/macOS. Sin probar.
    if (Platform.isIOS && allowNetwork) {
      handler = PMProgressHandler();
      handler.stream.listen((s) => onProgress?.call(s.progress));
    }
    final file = await asset.loadFile(isOrigin: true, progressHandler: handler);
    if (file == null) return null;
    // iOS entrega una copia temporal; Android, la ruta real del original.
    return OriginFile(file, isTemporary: Platform.isIOS);
  }

  @override
  Future<Uint8List?> thumbnail(String assetId, {int size = 256}) async {
    final asset = await AssetEntity.fromId(assetId);
    return asset?.thumbnailDataWithSize(
      ThumbnailSize.square(size),
      format: ThumbnailFormat.jpeg,
      quality: 80,
    );
  }

  /// Android 11+: UNA petición `MediaStore.createDeleteRequest` con todas las
  /// URIs (un solo diálogo del sistema); iOS: un solo `performChanges` (un
  /// diálogo). Android 10 pide confirmación por archivo (límite del sistema).
  /// El troceo de listas enormes lo hace `GalleryImportService` (D87).
  @override
  Future<List<String>> deleteAssets(List<String> assetIds) =>
      AutoLockSuspension.instance.run(
        () => PhotoManager.editor.deleteWithIds(assetIds),
      );

  /// S-03: `PhotoManager.clearFileCache()` (photo_manager 3.12.0, verificado
  /// en la fuente): Android -> `Glide.clearMemory()` + `Glide.clearDiskCache()`
  /// (`cache/image_manager_disk_cache/`, PNG/JPEG en claro de las miniaturas)
  /// y los `cache/pm_*` (copias completas del original en Android 10);
  /// iOS -> su caché de archivos exportados. Sin probar en iOS.
  @override
  Future<void> clearPlainCaches() => clearPhotoManagerCaches();

  /// Igual que [clearPlainCaches], sin instancia (arranque de la app).
  static Future<void> clearPhotoManagerCaches() async {
    try {
      await PhotoManager.clearFileCache();
    } on Object {
      // Plugin no disponible (pruebas/escritorio) o fallo puntual: se
      // reintenta en el próximo lote / arranque.
    }
  }
}
