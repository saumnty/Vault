import 'dart:io';

/// Calidad de video al importar.
enum VideoQualityOption {
  original('Original'),
  p1080('1080p'),
  p720('720p');

  const VideoQualityOption(this.label);
  final String label;
}

/// Resultado de comprimir un video.
class CompressedVideo {
  const CompressedVideo(this.file, this.sizeBytes);
  final File file;
  final int sizeBytes;
}

/// Compresión de video inyectable (real: `video_compress`).
abstract interface class VideoCompressor {
  /// Comprime [source]. `null` si falló o se canceló (el llamador decide si
  /// usa el original). [onProgress] va de 0 a 1.
  Future<CompressedVideo?> compress(
    File source,
    VideoQualityOption quality, {
    void Function(double progress)? onProgress,
  });

  /// Cancela la compresión en curso (si hay).
  Future<void> cancel();

  /// Borra los archivos temporales del compresor.
  Future<void> cleanup();
}

/// Bitrates de referencia (bits/s) para ESTIMAR el tamaño antes de comprimir.
/// Son aproximaciones: el resultado real depende del contenido y del
/// codificador del dispositivo.
const int _estimatedBitrate1080 = 5000000;
const int _estimatedBitrate720 = 2500000;

/// Tamaño estimado en bytes de un video de [duration] con [quality].
/// Con `original` devuelve [originalBytes] (puede ser null si se desconoce).
/// Nunca estima más que el original conocido.
int? estimateVideoBytes({
  required Duration duration,
  required VideoQualityOption quality,
  int? originalBytes,
}) {
  if (quality == VideoQualityOption.original) return originalBytes;
  final bitrate = quality == VideoQualityOption.p1080
      ? _estimatedBitrate1080
      : _estimatedBitrate720;
  final estimate = (duration.inMilliseconds * bitrate / 8000).round();
  if (originalBytes != null && estimate > originalBytes) return originalBytes;
  return estimate;
}
