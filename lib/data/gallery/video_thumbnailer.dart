import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/logging/vault_log.dart';

/// Extrae una miniatura JPEG de un video LOCAL (fotograma central).
///
/// Es el origen "de respaldo" (y, para videos, el principal) de las miniaturas:
/// no depende de la fototeca ni de iCloud, solo del archivo ya materializado.
/// NUNCA lanza: devuelve `null` si no se pudo (códec raro, archivo dañado,
/// plugin ausente, tiempo agotado).
abstract interface class VideoThumbnailer {
  Future<Uint8List?> thumbnail(File video, {int size = 256});
}

/// Implementación real por el canal nativo `vault/security`, método
/// `videoThumbnail` (Android: MediaMetadataRetriever; iOS:
/// AVAssetImageGenerator, // iOS: sin probar en dispositivo).
///
/// No se usa `video_compress.getByteThumbnail`: en iOS no responde nunca si no
/// puede generar el fotograma (el Future se queda colgado), devuelve el
/// fotograma a resolución completa y su posición por defecto (-1) no es
/// válida; `getFileThumbnail` además BORRA el archivo de origen.
class PlatformVideoThumbnailer implements VideoThumbnailer {
  PlatformVideoThumbnailer({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 20),
    bool? supported,
  }) : _channel = channel ?? const MethodChannel('vault/security'),
       _supported = supported ?? (Platform.isAndroid || Platform.isIOS);

  final MethodChannel _channel;
  final Duration timeout;
  final bool _supported;

  @override
  Future<Uint8List?> thumbnail(File video, {int size = 256}) async {
    // Solo móvil: en tests/escritorio no hay canal y, bajo FakeAsync, esperar
    // a un canal sin implementar cuelga.
    if (!_supported) return null;
    try {
      final bytes = await _channel
          .invokeMethod<Uint8List>('videoThumbnail', {
            'path': video.path,
            'size': size,
          })
          .timeout(timeout);
      if (bytes == null || bytes.isEmpty) {
        VaultLog.d('Fotograma de video no disponible', category: 'thumbs');
        return null;
      }
      return bytes;
    } on Object catch (e) {
      VaultLog.e('Fotograma de video falló', e, 'thumbs');
      return null;
    }
  }
}
