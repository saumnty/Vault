import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'gallery_asset_source.dart';

/// Implementación real sobre `photo_manager` 3.12.0.
///
/// SIN PROBAR en dispositivo (el emulador no arranca): permisos reales,
/// paginación, miniaturas, borrado e iCloud están sin verificar.
class PhotoManagerGallerySource implements GalleryAssetSource {
  AssetPathEntity? _all;

  @override
  Future<GalleryPermission> requestPermission() async {
    final state = await PhotoManager.requestPermissionExtend();
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
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate)],
      ),
    );
    return _all = paths.isEmpty ? null : paths.first;
  }

  @override
  Future<int> assetCount() async => (await _allPath())?.assetCountAsync ?? 0;

  @override
  Future<List<GalleryAsset>> listAssets({
    required int page,
    required int size,
  }) async {
    final path = await _allPath();
    if (path == null) return const [];
    final list = await path.getAssetListPaged(page: page, size: size);
    return [
      for (final a in list)
        if (a.type == AssetType.image || a.type == AssetType.video)
          GalleryAsset(
            id: a.id,
            type: a.type == AssetType.video
                ? GalleryAssetType.video
                : GalleryAssetType.image,
            title: a.title,
            duration: Duration(seconds: a.duration),
            width: a.width,
            height: a.height,
            createdAt: a.createDateTime,
          ),
    ];
  }

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

  @override
  Future<List<String>> deleteAssets(List<String> assetIds) =>
      PhotoManager.editor.deleteWithIds(assetIds);
}
