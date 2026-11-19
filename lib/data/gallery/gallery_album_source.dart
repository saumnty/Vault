import 'gallery_asset_source.dart';

/// Álbum de la galería del sistema (equivalente liviano de
/// `AssetPathEntity`). v2.2 (D86).
class GalleryAlbum {
  const GalleryAlbum({
    required this.id,
    required this.name,
    required this.count,
    this.isAll = false,
  });

  /// Android: `BUCKET_ID`; iOS: `localIdentifier` de la colección.
  final String id;

  /// Nombre visible (solo se muestra en pantalla; nunca se registra).
  final String name;

  /// Fotos y videos que contiene.
  final int count;

  /// `true` para «Recientes» / «Todas» (la colección con todo).
  final bool isAll;
}

/// Origen de galería con álbumes y búsqueda por id (D86). Es una interfaz
/// APARTE de [GalleryAssetSource] para que los orígenes existentes (y sus
/// fakes) sigan valiendo; la implementación real implementa las dos.
abstract interface class GalleryAlbumSource implements GalleryAssetSource {
  /// Álbumes con al menos un elemento; el de «todo» primero.
  Future<List<GalleryAlbum>> listAlbums();

  /// Página [page] (base 0) de [size] elementos del álbum [albumId], del más
  /// reciente al más antiguo. Nunca devuelve más de [size].
  Future<List<GalleryAsset>> listAlbumAssets(
    String albumId, {
    required int page,
    required int size,
  });

  /// Metadatos de un asset por id, o `null` si ya no existe en la galería.
  Future<GalleryAsset?> assetById(String id);
}

/// Bytes estimados que ocupará [asset] en la bóveda (para comprobar el
/// espacio libre ANTES de importar; nunca decide nada más). El tamaño real
/// solo se conoce al materializar el archivo.
///
/// * Conocido ([GalleryAsset.sizeBytes]): ese (o el estimado comprimido).
/// * Foto: ≈ 0,35 B por píxel (JPEG/HEIC de cámara), mínimo 200 KB; sin
///   dimensiones, 3 MB.
/// * Video original: duración × bitrate típico según la resolución (4K
///   45 Mbit/s, 1080p 17, 720p 10, menor 5); comprimido: [estimateVideo].
int estimateAssetBytes(
  GalleryAsset asset, {
  required bool compress,
  required int? Function(Duration duration) estimateVideo,
}) {
  final known = asset.sizeBytes;
  if (!asset.isVideo) {
    if (known != null) return known;
    final w = asset.width ?? 0;
    final h = asset.height ?? 0;
    if (w <= 0 || h <= 0) return 3 * 1024 * 1024;
    final est = (w * h * 0.35).round();
    return est < 200 * 1024 ? 200 * 1024 : est;
  }
  final side = [asset.width ?? 0, asset.height ?? 0].reduce(
    (a, b) => a > b ? a : b,
  );
  final bitrate = side >= 3000
      ? 45000000
      : side >= 1900
      ? 17000000
      : side >= 1200
      ? 10000000
      : 5000000;
  final secs = asset.duration.inMilliseconds / 1000;
  final original = known ?? (secs * bitrate / 8).round();
  if (!compress) return original;
  final c = estimateVideo(asset.duration);
  if (c == null) return original;
  return c < original ? c : original;
}
