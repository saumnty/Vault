import '../../core/crypto/secure_kv_store.dart';
import 'video_compressor.dart';

/// Preferencias de importación (locales, nunca salen del teléfono).
class GalleryImportPreferences {
  GalleryImportPreferences(this._store);

  final SecureKeyValueStore _store;

  static const String _kDeleteOriginals = 'pref.gallery.deleteOriginalsInCloud';
  static const String _kVideoQuality = 'pref.gallery.videoQuality';

  /// Calidad de video por defecto al importar (Ajustes, F8). `original` si
  /// nunca se eligió.
  Future<VideoQualityOption> getVideoQuality() async {
    try {
      final name = await _store.read(_kVideoQuality);
      for (final q in VideoQualityOption.values) {
        if (q.name == name) return q;
      }
    } on Object {
      // sin preferencia legible: valor por defecto
    }
    return VideoQualityOption.original;
  }

  Future<void> setVideoQuality(VideoQualityOption value) async {
    try {
      await _store.write(_kVideoQuality, value.name);
    } on Object {
      // Si no se puede guardar, queda el valor anterior.
    }
  }

  /// "Borrar originales cuando estén en la nube". Apagada por defecto. Solo
  /// es una preferencia: el borrado real pasa por
  /// `GalleryImportService.deleteOriginalsConfirmedInCloud`.
  Future<bool> getDeleteOriginalsWhenInCloud() async {
    try {
      return (await _store.read(_kDeleteOriginals)) == '1';
    } on Object {
      return false;
    }
  }

  Future<void> setDeleteOriginalsWhenInCloud(bool value) async {
    try {
      await _store.write(_kDeleteOriginals, value ? '1' : '0');
    } on Object {
      // Si no se puede guardar, queda el valor anterior (apagado).
    }
  }
}
