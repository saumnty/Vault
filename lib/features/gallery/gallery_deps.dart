import '../../data/gallery/gallery_asset_source.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/gallery/import_preferences.dart';

/// Dependencias de la importación desde galería (inyectables en pruebas).
class GalleryDeps {
  const GalleryDeps({
    required this.source,
    required this.service,
    required this.preferences,
  });

  final GalleryAssetSource source;
  final GalleryImportService service;
  final GalleryImportPreferences preferences;
}
