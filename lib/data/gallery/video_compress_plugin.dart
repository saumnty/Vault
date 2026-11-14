import 'dart:io';

import 'package:video_compress/video_compress.dart' as vc;

import 'video_compressor.dart';

/// Implementación real sobre `video_compress` 3.1.4.
///
/// Limitaciones conocidas (sin probar en dispositivo): el plugin permite una
/// sola compresión a la vez; en Android la cancelación puede no interrumpir de
/// inmediato; en iOS usa AVAssetExportSession (presets por resolución).
class VideoCompressPlugin implements VideoCompressor {
  @override
  Future<CompressedVideo?> compress(
    File source,
    VideoQualityOption quality, {
    void Function(double progress)? onProgress,
  }) async {
    final target = switch (quality) {
      VideoQualityOption.original => null,
      VideoQualityOption.p1080 => vc.VideoQuality.Res1920x1080Quality,
      VideoQualityOption.p720 => vc.VideoQuality.Res1280x720Quality,
    };
    if (target == null) return null;
    final sub = vc.VideoCompress.compressProgress$.subscribe(
      (p) => onProgress?.call((p / 100).clamp(0.0, 1.0)),
    );
    try {
      final info = await vc.VideoCompress.compressVideo(
        source.path,
        quality: target,
        deleteOrigin: false,
      );
      final file = info?.file;
      if (info == null || file == null || info.isCancel == true) return null;
      return CompressedVideo(file, info.filesize ?? await file.length());
    } finally {
      sub.unsubscribe();
    }
  }

  @override
  Future<void> cancel() => vc.VideoCompress.cancelCompression();

  @override
  Future<void> cleanup() async {
    await vc.VideoCompress.deleteAllCache();
  }
}
