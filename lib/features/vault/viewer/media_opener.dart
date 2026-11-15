import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../core/services/plain_temp_manager.dart';
import '../../../data/cloud/cloud_storage.dart';
import '../../../data/models/vault_item_model.dart';
import '../../../data/sync/vault_file_fetcher.dart';

/// Fase de apertura de un archivo (para la barra de progreso del visor).
enum MediaPhase {
  /// Bajando el `.vault` de Drive (solo si no estaba en el dispositivo).
  downloading,

  /// Descifrando a un temporal (video completo-primero).
  decrypting,
}

class MediaProgress {
  const MediaProgress(this.phase, this.fraction);
  final MediaPhase phase;

  /// 0..1, o `null` si no se conoce.
  final double? fraction;
}

typedef MediaProgressCallback = void Function(MediaProgress progress);

/// Error de apertura ya traducido para el usuario.
class MediaOpenError {
  const MediaOpenError(this.message, {this.canRetry = true});
  final String message;
  final bool canRetry;
}

/// Se abandonó la apertura (visor cerrado o bóveda bloqueada).
class MediaOpenCancelled implements Exception {
  const MediaOpenCancelled();
}

/// Traduce cualquier excepción de apertura a un mensaje en español.
MediaOpenError describeMediaError(Object e) => switch (e) {
  CloudNoNetworkException() => const MediaOpenError(
    'Sin conexión a internet. Este archivo solo está en la nube; '
    'conéctate y vuelve a intentarlo.',
  ),
  CloudNotAuthenticatedException() => const MediaOpenError(
    'Inicia sesión con Google (hoja Sincronización) para descargar este '
    'archivo.',
  ),
  CloudNotFoundException() => const MediaOpenError(
    'La copia en la nube ya no existe.',
    canRetry: false,
  ),
  CloudException(:final message) => MediaOpenError(message),
  VaultFetchUnavailableException(:final message) => MediaOpenError(
    message,
    canRetry: false,
  ),
  VaultFetchVerificationException() => const MediaOpenError(
    'La copia descargada no coincide con la original (tamaño o MD5). '
    'Inténtalo de nuevo.',
  ),
  VaultCryptoException() => const MediaOpenError(
    'No se pudo descifrar: el archivo está dañado o fue alterado.',
    canRetry: false,
  ),
  MediaOpenCancelled() => const MediaOpenError('Cancelado'),
  _ => const MediaOpenError('No se pudo abrir el archivo.'),
};

/// Origen de un video para el reproductor del visor.
///
/// F6a: [FullDecryptVideoSource] (descifra TODO a un temporal y reproduce).
/// F6b enchufará otro origen (streaming por bloques con servidor local) que
/// solo debe devolver un `VideoPlayerController` listo en [open] y liberar
/// recursos en [release].
abstract interface class VideoSource {
  /// Prepara el video y devuelve el controlador YA inicializado.
  /// Lanza [MediaOpenCancelled] si se llama a [release] durante la apertura.
  Future<VideoPlayerController> open({MediaProgressCallback? onProgress});

  /// Libera el controlador y los temporales. Idempotente; se llama al cerrar
  /// el visor/cambiar de página.
  Future<void> release();
}

/// Qué necesita el visor para abrir medios.
abstract interface class MediaOpener {
  /// Bytes de la imagen en claro, en MEMORIA (nada en claro en disco).
  Future<Uint8List> loadImage(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  });

  /// Origen de video para el item.
  VideoSource videoSource(VaultItemModel item);
}

/// Implementación real: `.vault` local (o descargado de Drive) + subllave
/// "files" de la sesión.
class VaultMediaOpener implements MediaOpener {
  VaultMediaOpener({
    required this.fetcher,
    required this.filesKey,
    PlainTempManager? temp,
    CryptoService? crypto,
    this.onOpened,
    this.controllerFactory = VideoPlayerController.file,
  }) : temp = temp ?? PlainTempManager.instance,
       crypto = crypto ?? CryptoService();

  final VaultFileFetcher fetcher;

  /// `null` = bóveda bloqueada.
  final SecretKey? Function() filesKey;
  final PlainTempManager temp;
  final CryptoService crypto;

  /// Tras abrir un archivo (se aplica el límite de la caché).
  final Future<void> Function()? onOpened;

  /// Crea el controlador de video a partir del temporal (inyectable).
  final VideoPlayerController Function(File) controllerFactory;

  SecretKey requireKey() {
    final k = filesKey();
    if (k == null) throw StateError('La bóveda está bloqueada');
    return k;
  }

  @override
  Future<Uint8List> loadImage(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  }) async {
    final file = await fetcher.ensureLocal(
      item,
      onProgress: (got, total) => onProgress?.call(
        MediaProgress(MediaPhase.downloading, total <= 0 ? null : got / total),
      ),
    );
    final reader = await crypto.openReader(file, requireKey());
    try {
      return await reader.readRange(0, reader.plaintextLength);
    } finally {
      await reader.close();
      unawaited(notifyOpened());
    }
  }

  @override
  VideoSource videoSource(VaultItemModel item) =>
      FullDecryptVideoSource(opener: this, item: item);

  Future<void> notifyOpened() async {
    try {
      await onOpened?.call();
    } on Object {
      // la purga es best-effort
    }
  }
}

/// Video "completo-primero": descarga (si hace falta), descifra el `.vault`
/// ENTERO a `tmp_plain/` con progreso y reproduce con `video_player`.
/// El temporal se borra en [release].
class FullDecryptVideoSource implements VideoSource {
  FullDecryptVideoSource({required this.opener, required this.item});

  final VaultMediaOpener opener;
  final VaultItemModel item;

  File? _temp;
  VideoPlayerController? _controller;
  final CloudCancelToken _cancel = CloudCancelToken();
  bool _released = false;

  /// Temporal actual (solo pruebas).
  File? get tempFile => _temp;

  @override
  Future<VideoPlayerController> open({
    MediaProgressCallback? onProgress,
  }) async {
    void report(MediaPhase phase, double? f) =>
        onProgress?.call(MediaProgress(phase, f));
    try {
      final local = await opener.fetcher.ensureLocal(
        item,
        cancel: _cancel,
        onProgress: (got, total) =>
            report(MediaPhase.downloading, total <= 0 ? null : got / total),
      );
      _checkAlive();
      final key = opener.requireKey();
      final ext = p.extension(item.name);
      final plain = opener.temp.newTempFile(
        extension: ext.isEmpty ? '.mp4' : ext,
      );
      _temp = plain;
      report(MediaPhase.decrypting, 0);
      final reader = await opener.crypto.openReader(local, key);
      RandomAccessFile? out;
      try {
        out = await plain.open(mode: FileMode.write);
        final total = reader.blockCount;
        for (var i = 0; i < total; i++) {
          _checkAlive();
          await out.writeFrom(await reader.decryptBlock(i));
          report(MediaPhase.decrypting, (i + 1) / total);
        }
        await out.flush();
      } finally {
        await out?.close();
        await reader.close();
      }
      _checkAlive();
      final controller = opener.controllerFactory(plain);
      _controller = controller;
      await controller.initialize();
      _checkAlive();
      unawaited(opener.notifyOpened());
      return controller;
    } catch (e) {
      await release();
      rethrow;
    }
  }

  void _checkAlive() {
    if (_released) throw const MediaOpenCancelled();
  }

  @override
  Future<void> release() async {
    _released = true;
    _cancel.cancel();
    final c = _controller;
    _controller = null;
    try {
      await c?.dispose();
    } on Object {
      // ya liberado
    }
    final f = _temp;
    _temp = null;
    if (f != null) await opener.temp.release(f);
  }
}
