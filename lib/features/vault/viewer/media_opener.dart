import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../core/services/plain_temp_manager.dart';
import '../../../core/session/vault_session.dart';
import '../../../core/streaming/vault_stream_server.dart';
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

/// El reproductor nativo informó un error durante la reproducción y el origen
/// no tiene una causa más concreta (p. ej. códec no soportado).
class VideoPlaybackException implements Exception {
  const VideoPlaybackException();
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
  VideoPlaybackException() => const MediaOpenError(
    'El reproductor no pudo leer este video.',
  ),
  _ => const MediaOpenError('No se pudo abrir el archivo.'),
};

/// Origen de un video para el reproductor del visor.
///
/// * [StreamingVideoSource] (F6b, por defecto): servidor HTTP en loopback que
///   descifra bloque a bloque al vuelo; nada en claro en disco.
/// * [FullDecryptVideoSource] (F6a, respaldo): descifra TODO a un temporal.
abstract interface class VideoSource {
  /// Prepara el video y devuelve el controlador YA inicializado.
  /// Lanza [MediaOpenCancelled] si se llama a [release] durante la apertura.
  Future<VideoPlayerController> open({MediaProgressCallback? onProgress});

  /// Libera el controlador, el servidor y los temporales. Idempotente; se
  /// llama al cerrar el visor, cambiar de página o pasar a segundo plano.
  Future<void> release();

  /// Causa concreta de un error del reproductor durante la reproducción
  /// (p. ej. un bloque que no autenticó), o `null`.
  Object? get playbackFailure;
}

/// Streaming activo por defecto; `--dart-define=VAULT_VIDEO_STREAMING=false`
/// fuerza completo-primero (diagnóstico).
const bool kVideoStreamingDefault = bool.fromEnvironment(
  'VAULT_VIDEO_STREAMING',
  defaultValue: true,
);

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
    this.networkControllerFactory = _networkController,
    this.streaming = kVideoStreamingDefault,
    this.session,
    this.streamInitTimeout = const Duration(seconds: 30),
    this.markInUse,
    this.releaseInUse,
  }) : temp = temp ?? PlainTempManager.instance,
       crypto = crypto ?? CryptoService();

  static VideoPlayerController _networkController(Uri uri) =>
      VideoPlayerController.networkUrl(uri);

  final VaultFileFetcher fetcher;

  /// Subllave "files" de la generación de llave de un item (D60;
  /// `VaultSession.filesKeyFor`). `null` = bóveda bloqueada (o la sesión no
  /// tiene esa generación).
  final SecretKey? Function(int keyGen) filesKey;
  final PlainTempManager temp;
  final CryptoService crypto;

  /// Tras abrir un archivo (se aplica el límite de la caché).
  final Future<void> Function()? onOpened;

  /// Crea el controlador de video a partir del temporal (inyectable).
  final VideoPlayerController Function(File) controllerFactory;

  /// Crea el controlador para la URL del servidor local (inyectable).
  final VideoPlayerController Function(Uri) networkControllerFactory;

  /// `true` = [StreamingVideoSource] (con caída a completo-primero).
  final bool streaming;

  /// Sesión cuyo bloqueo cierra el servidor del origen (además del cierre
  /// global [VaultStreamServer.closeAllNow]).
  final VaultSession? session;

  /// Tope para que el reproductor inicialice contra el servidor local antes
  /// de caer a completo-primero.
  final Duration streamInitTimeout;

  /// El `.vault` del item queda protegido de la purga LRU mientras se
  /// reproduce en streaming (CacheManager.markInUse / releaseInUse).
  final void Function(String itemId)? markInUse;
  final void Function(String itemId)? releaseInUse;

  /// Subllave para leer un item de la generación [keyGen]. Lanza
  /// [StateError] si la bóveda está bloqueada.
  SecretKey requireKey(int keyGen) {
    final k = filesKey(keyGen);
    if (k == null) throw StateError('La bóveda está bloqueada');
    return k;
  }

  /// Ejecuta [action] con la fila MÁS RECIENTE del item (ruta, `fileId` y
  /// generación actuales; D60). Si el archivo desapareció entre la lectura de
  /// la fila y la apertura (la rotación lo re-cifró justo entonces) y la
  /// fila cambió, se reintenta una vez con la fila nueva.
  Future<T> withFreshItem<T>(
    VaultItemModel item,
    Future<T> Function(VaultItemModel fresh) action,
  ) async {
    final fresh = await fetcher.refresh(item);
    try {
      return await action(fresh);
    } on FileSystemException {
      final again = await fetcher.refresh(fresh);
      if (again.keyGen == fresh.keyGen &&
          again.encryptedPath == fresh.encryptedPath) {
        rethrow;
      }
      return action(again);
    }
  }

  @override
  Future<Uint8List> loadImage(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  }) => withFreshItem(item, (fresh) async {
    final file = await fetcher.ensureLocal(
      fresh,
      onProgress: (got, total) => onProgress?.call(
        MediaProgress(MediaPhase.downloading, total <= 0 ? null : got / total),
      ),
    );
    final reader = await crypto.openReader(
      file,
      requireKey(fresh.keyGen),
      expectedFileId: fresh.fileId,
    );
    try {
      return await reader.readRange(0, reader.plaintextLength);
    } finally {
      await reader.close();
      unawaited(notifyOpened());
    }
  });

  @override
  VideoSource videoSource(VaultItemModel item) => streaming
      ? StreamingVideoSource(opener: this, item: item)
      : FullDecryptVideoSource(opener: this, item: item);

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
      // D60: fila fresca (generación, ruta y fileId actuales).
      final fresh = await opener.fetcher.refresh(item);
      final local = await opener.fetcher.ensureLocal(
        fresh,
        cancel: _cancel,
        onProgress: (got, total) =>
            report(MediaPhase.downloading, total <= 0 ? null : got / total),
      );
      _checkAlive();
      final key = opener.requireKey(fresh.keyGen);
      final ext = p.extension(item.name);
      final plain = opener.temp.newTempFile(
        extension: ext.isEmpty ? '.mp4' : ext,
      );
      _temp = plain;
      report(MediaPhase.decrypting, 0);
      final reader = await opener.crypto.openReader(
        local,
        key,
        expectedFileId: fresh.fileId,
      );
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
  Object? get playbackFailure => null;

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

/// Video por STREAMING (F6b): `.vault` local (si no está, primero lo baja
/// VaultFileFetcher con verificación tamaño+MD5) → [VaultFileReader] →
/// [VaultStreamServer] en 127.0.0.1 → `VideoPlayerController.networkUrl`.
/// Nada del video en claro toca el disco; el primer fotograma no espera a
/// descifrar todo y el seek pide rangos HTTP (bloques bajo demanda).
///
/// Si el streaming falla AL INICIALIZAR por causas ajenas al archivo
/// (plataforma que no permite el loopback, el reproductor no conecta,
/// timeout…) cae automáticamente a [FullDecryptVideoSource] con un aviso en
/// depuración. No cae si el archivo está dañado (un descifrado completo
/// fallaría igual), si no hay copia/red, si la bóveda se bloqueó o si se
/// canceló.
class StreamingVideoSource implements VideoSource {
  StreamingVideoSource({required this.opener, required this.item});

  final VaultMediaOpener opener;
  final VaultItemModel item;

  final CloudCancelToken _cancel = CloudCancelToken();
  VaultStreamServer? _server;
  VideoPlayerController? _controller;
  FullDecryptVideoSource? _fallback;
  VaultCryptoException? _integrity;
  bool _released = false;
  bool _lockHooked = false;
  bool _inUse = false;
  final Completer<void> _releasedSignal = Completer<void>();

  /// Servidor activo (solo pruebas/diagnóstico).
  VaultStreamServer? get server => _server;

  /// `true` si se cayó a completo-primero.
  bool get usedFallback => _fallback != null;

  /// Origen de respaldo en uso (solo pruebas).
  FullDecryptVideoSource? get fallback => _fallback;

  @override
  Object? get playbackFailure => _integrity ?? _fallback?.playbackFailure;

  @override
  Future<VideoPlayerController> open({
    MediaProgressCallback? onProgress,
  }) async {
    final watch = Stopwatch()..start();
    // Antes de asegurar la copia local: que la purga LRU no la borre entre
    // la descarga/comprobación y la apertura, ni durante la reproducción.
    opener.markInUse?.call(item.id);
    _inUse = true;
    try {
      // D60: fila fresca (generación, ruta y fileId actuales). Si el archivo
      // desaparece por un re-cifrado justo ahora, la caída a completo-primero
      // vuelve a leer la fila.
      final fresh = await opener.fetcher.refresh(item);
      final local = await opener.fetcher.ensureLocal(
        fresh,
        cancel: _cancel,
        onProgress: (got, total) => onProgress?.call(
          MediaProgress(
            MediaPhase.downloading,
            total <= 0 ? null : got / total,
          ),
        ),
      );
      _checkAlive();
      final key = opener.requireKey(fresh.keyGen);
      final mime = videoMimeType(mimeType: item.mimeType, fileName: item.name);
      // verifyFinal (por defecto): autentica ya la longitud total
      // (Content-Length fiable) y detecta truncados antes de servir nada.
      final reader = await opener.crypto.openReader(
        local,
        key,
        expectedFileId: fresh.fileId,
      );
      if (_released) {
        await reader.close();
        throw const MediaOpenCancelled();
      }
      final VaultStreamServer server;
      try {
        server = await VaultStreamServer.start(
          reader: reader,
          mimeType: mime,
          onIntegrityFailure: (e) => _integrity = e,
        );
      } catch (_) {
        await reader.close();
        rethrow;
      }
      _server = server;
      opener.session?.addOnClear(_onLock);
      _lockHooked = true;
      _checkAlive();
      final controller = opener.networkControllerFactory(server.uri);
      _controller = controller;
      // Si se libera durante la inicialización no se espera al reproductor
      // (su inicialización puede no terminar nunca tras cerrar el servidor).
      await Future.any([
        controller.initialize(),
        _releasedSignal.future,
      ]).timeout(opener.streamInitTimeout);
      _checkAlive();
      final integrity = _integrity;
      if (integrity != null) throw integrity;
      if (!kReleaseMode) {
        debugPrint(
          '[vault-video] streaming listo en ${watch.elapsedMilliseconds} ms '
          '(servidos ${server.stats.bytesSent} B, '
          '${server.stats.blocksDecrypted} bloques)',
        );
      }
      unawaited(opener.notifyOpened());
      return controller;
    } catch (e) {
      final integrity = _integrity;
      await _releaseStreaming();
      if (_released) throw const MediaOpenCancelled();
      if (integrity != null) throw integrity;
      if (!_canFallBack(e)) rethrow;
      if (kDebugMode) {
        debugPrint(
          '[vault-video] AVISO: streaming no disponible '
          '(${e.runtimeType}); se usa completo-primero',
        );
      }
      final fb = FullDecryptVideoSource(opener: opener, item: item);
      _fallback = fb;
      return fb.open(onProgress: onProgress);
    }
  }

  /// Solo se cae a completo-primero si el problema es del reproductor o de
  /// la plataforma, no del archivo, de la nube o del estado de la bóveda.
  static bool _canFallBack(Object e) => switch (e) {
    VaultCryptoException() ||
    MediaOpenCancelled() ||
    CloudException() ||
    VaultFetchUnavailableException() ||
    VaultFetchVerificationException() ||
    StateError() => false,
    _ => true,
  };

  void _checkAlive() {
    if (_released) throw const MediaOpenCancelled();
  }

  /// Bloqueo: cierre inmediato del servidor (la parte síncrona corta ya las
  /// conexiones); el visor se cierra y llamará a [release].
  void _onLock() {
    final s = _server;
    if (s != null) unawaited(s.close());
  }

  Future<void> _releaseStreaming() async {
    if (_inUse) {
      _inUse = false;
      opener.releaseInUse?.call(item.id);
    }
    if (_lockHooked) {
      opener.session?.removeOnClear(_onLock);
      _lockHooked = false;
    }
    final c = _controller;
    _controller = null;
    final s = _server;
    _server = null;
    // Primero el servidor (corta conexiones y deja de descifrar), luego el
    // reproductor.
    if (s != null) await s.close();
    if (c == null) return;
    // `dispose()` de video_player espera a que termine la creación nativa;
    // si la creación falló o sigue colgada (timeout) esa espera no acaba
    // nunca. Solo se espera si el controlador llegó a inicializarse.
    final disposing = c.dispose().catchError((Object _) {});
    if (c.value.isInitialized) await disposing;
  }

  @override
  Future<void> release() async {
    _released = true;
    if (!_releasedSignal.isCompleted) _releasedSignal.complete();
    _cancel.cancel();
    await _releaseStreaming();
    final fb = _fallback;
    if (fb != null) await fb.release();
  }
}
