import 'dart:io';
import 'dart:typed_data';

/// Tipo de elemento de la galería que se puede importar.
enum GalleryAssetType { image, video }

/// Resultado de pedir permiso a la fototeca.
enum GalleryPermission {
  /// Acceso completo.
  granted,

  /// iOS: el usuario eligió "fotos seleccionadas". Solo se ve parte.
  limited,

  /// Denegado (o restringido): hay que enviar al usuario a Ajustes.
  denied,
}

/// Elemento de la galería del sistema (equivalente liviano de `AssetEntity`).
class GalleryAsset {
  const GalleryAsset({
    required this.id,
    required this.type,
    this.title,
    this.mimeType,
    this.duration = Duration.zero,
    this.sizeBytes,
    this.width,
    this.height,
    this.createdAt,
  });

  /// Id en la galería del sistema (se guarda como `sourceAssetId`).
  final String id;
  final GalleryAssetType type;

  /// Nombre de archivo si el sistema lo conoce.
  final String? title;
  final String? mimeType;
  final Duration duration;

  /// Tamaño del original si se conoce (en el selector real normalmente no:
  /// calcularlo exige materializar el archivo).
  final int? sizeBytes;
  final int? width;
  final int? height;
  final DateTime? createdAt;

  bool get isVideo => type == GalleryAssetType.video;
}

/// Archivo original materializado de un asset.
class OriginFile {
  const OriginFile(this.file, {this.isTemporary = false});

  final File file;

  /// `true` si es una copia temporal creada para nosotros (iOS exporta una
  /// copia; Android devuelve la ruta real, que NUNCA debe borrarse).
  final bool isTemporary;
}

/// Origen de los assets de la galería. Se inyecta para probar con fakes; la
/// implementación real usa `photo_manager`.
abstract interface class GalleryAssetSource {
  /// Pide permiso de lectura de fotos y videos.
  Future<GalleryPermission> requestPermission();

  /// Abre los ajustes de la app para cambiar el permiso.
  Future<void> openSettings();

  /// Cantidad total de assets (fotos + videos).
  Future<int> assetCount();

  /// Página de assets, del más reciente al más antiguo.
  Future<List<GalleryAsset>> listAssets({required int page, required int size});

  /// `false` si el original solo está en iCloud (iOS). En Android siempre
  /// `true`.
  Future<bool> isLocallyAvailable(String assetId);

  /// Materializa el archivo original. Con [allowNetwork] puede descargarlo
  /// de iCloud (iOS) informando [onProgress] (0..1). `null` si no existe.
  Future<OriginFile?> originFile(
    String assetId, {
    bool allowNetwork = false,
    void Function(double progress)? onProgress,
  });

  /// Miniatura JPEG de lado máximo [size] px (para video, un fotograma).
  Future<Uint8List?> thumbnail(String assetId, {int size = 256});

  /// Borra originales de la galería (diálogo del sistema incluido). Devuelve
  /// los ids realmente borrados.
  Future<List<String>> deleteAssets(List<String> assetIds);

  /// Borra las cachés EN CLARO que deja el plugin en el almacenamiento de la
  /// app (S-03: miniaturas de Glide en disco y, en Android 10, copias
  /// completas `pm_<id>_o_<nombre>`). Se llama al terminar cada lote de
  /// importación, tras borrar originales y al arrancar. Nunca debe lanzar.
  Future<void> clearPlainCaches();
}
