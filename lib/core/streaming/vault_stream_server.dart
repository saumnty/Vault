import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crypto/vault_file_format.dart';

// =============================================================================
// SERVIDOR HTTP LOCAL DE STREAMING (F6b)
// =============================================================================
//
// POR QUÉ UN SERVIDOR LOCAL
//   `video_player` 2.11.1 solo acepta asset / archivo / URL de red / content
//   URI. No permite inyectar un DataSource propio (ExoPlayer) ni un
//   AVAssetResourceLoaderDelegate (AVPlayer) desde Dart. Para reproducir sin
//   escribir el video en claro en disco, la única vía con el plugin oficial es
//   servirle una URL http://127.0.0.1 que descifra bloque a bloque al vuelo.
//
// ALTERNATIVAS DESCARTADAS
//   * Descifrar todo a un temporal (F6a, se conserva como RESPALDO): deja el
//     video completo en claro en disco mientras se reproduce y hay que esperar
//     al descifrado completo antes del primer fotograma.
//   * Plugin nativo propio (DataSource de Media3 + resource loader de
//     AVFoundation): sin servidor, pero duplica el formato .vault en Kotlin y
//     Swift (dos implementaciones criptográficas más que auditar) y el lado
//     iOS no se puede probar aquí.
//   * media_kit/libmpv o fvp: dependencias nativas grandes; tampoco exponen un
//     origen de bytes personalizado estable desde Dart.
//   * Pipe con nombre / memfd: no es portable a iOS y ExoPlayer necesita seek
//     (acceso aleatorio), que un pipe no ofrece.
//   * HLS cifrado (AES-128): exigiría re-cifrar el video en otro formato.
//
// MEDIDAS DE SEGURIDAD
//   * Escucha SOLO en 127.0.0.1 con puerto efímero aleatorio (bind(…, 0)).
//   * Rechaza conexiones cuyo origen no sea loopback.
//   * Ruta única por servidor `/v/<token><ext>`, token de 256 bits de
//     Random.secure() en base64url; comparación en tiempo constante. Cualquier
//     otra ruta o token → 404 vacío (no se distingue "token malo" de "ruta
//     mala"). Métodos distintos de GET/HEAD → 405 vacío.
//   * Cabecera Host obligatoria e igual a 127.0.0.1:<puerto> o
//     localhost:<puerto> (defensa contra DNS rebinding desde un navegador).
//   * Un solo archivo por servidor/token; el servidor se cierra al liberar el
//     origen, al cambiar de página, al pasar la app a segundo plano y al
//     bloquear ([closeAllNow], enganchado a VaultSession.addOnClear). Al
//     cerrar se cortan también las conexiones activas.
//   * Cada bloque se AUTENTICA (AES-GCM) antes de enviar un solo byte suyo. Si
//     un bloque falla: si aún no se enviaron cabeceras → 500 vacío; si la
//     respuesta ya estaba en curso → se destruye el socket (el cliente ve una
//     respuesta incompleta, nunca datos sin autenticar). Desde ese momento el
//     servidor queda "envenenado" y responde 500 a todo.
//   * La longitud total se autentica al abrir el lector (verifyFinal), así
//     Content-Length/Content-Range son fiables.
//   * Sin CORS, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`,
//     sin cabeceras por defecto de dart:io.
//   * Tope de conexiones simultáneas y timeout de inactividad (anti-DoS local).
//   * Logs solo en depuración/perfil y solo con contadores y duraciones: nunca
//     nombres, rutas, tokens ni llaves.
//
// MEMORIA
//   Por conexión como mucho ~2 bloques en claro (el que se escribe y el
//   siguiente, que se descifra mientras tanto) + lo que acepte el buffer del
//   socket. Con contrapresión (`flush` antes de seguir) nunca se lee el
//   archivo entero si el cliente no lo consume. Si el cliente cierra la
//   conexión se cancela el descifrado pendiente.
// =============================================================================

/// Resultado de interpretar la cabecera Range para un recurso de [total] B.
sealed class ByteRangeRequest {
  const ByteRangeRequest();
}

/// Sin Range (o Range ignorable): respuesta 200 con el recurso completo.
class FullRange extends ByteRangeRequest {
  const FullRange();
}

/// Rango válido [start, endInclusive] → 206.
class PartialRange extends ByteRangeRequest {
  const PartialRange(this.start, this.endInclusive);
  final int start;
  final int endInclusive;
  int get length => endInclusive - start + 1;
}

/// Rango sintácticamente válido pero fuera del recurso → 416.
class UnsatisfiableRange extends ByteRangeRequest {
  const UnsatisfiableRange();
}

final RegExp _rangeSpec = RegExp(r'^(\d{0,18})-(\d{0,18})$');

/// Interpreta `Range: bytes=…` según RFC 9110 §14 (un solo rango).
///
/// * `bytes=a-b` (b se recorta a total-1), `bytes=a-`, `bytes=-n` (sufijo).
/// * Varios rangos, otra unidad o sintaxis inválida → se IGNORA (200 completo),
///   como permite la RFC.
/// * Primer byte ≥ total, sufijo de 0, o recurso vacío → 416.
ByteRangeRequest parseRangeHeader(String? header, int total) {
  if (header == null) return const FullRange();
  final h = header.trim();
  final eq = h.indexOf('=');
  if (eq < 0 || h.substring(0, eq).trim().toLowerCase() != 'bytes') {
    return const FullRange();
  }
  final spec = h.substring(eq + 1).trim();
  if (spec.contains(',')) return const FullRange();
  final m = _rangeSpec.firstMatch(spec);
  if (m == null) return const FullRange();
  final a = m.group(1)!;
  final b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return const FullRange();
  if (a.isEmpty) {
    // Sufijo: los últimos n bytes.
    final n = int.parse(b);
    if (n == 0 || total == 0) return const UnsatisfiableRange();
    return PartialRange(max(0, total - n), total - 1);
  }
  final start = int.parse(a);
  if (b.isNotEmpty) {
    final end = int.parse(b);
    if (end < start) return const FullRange(); // range-spec inválido
    if (start >= total) return const UnsatisfiableRange();
    return PartialRange(start, min(end, total - 1));
  }
  if (start >= total) return const UnsatisfiableRange();
  return PartialRange(start, total - 1);
}

/// MIME de video a partir del MIME guardado o de la extensión del nombre.
String videoMimeType({String? mimeType, required String fileName}) {
  final m = mimeType?.trim().toLowerCase();
  if (m != null && m.startsWith('video/')) return m;
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp4' || 'm4v' => 'video/mp4',
    'mov' || 'qt' => 'video/quicktime',
    'webm' => 'video/webm',
    'mkv' => 'video/x-matroska',
    '3gp' => 'video/3gpp',
    '3g2' => 'video/3gpp2',
    'ts' => 'video/mp2t',
    'avi' => 'video/x-msvideo',
    _ => 'video/mp4',
  };
}

/// Extensión (con punto) para la URL a partir del MIME.
///
/// // iOS: AVPlayer decide el contenedor por Content-Type, pero una extensión
/// coherente en la ruta evita heurísticas raras con URLs sin extensión.
String videoExtensionFor(String mimeType) => switch (mimeType) {
  'video/quicktime' => '.mov',
  'video/webm' => '.webm',
  'video/x-matroska' => '.mkv',
  'video/3gpp' => '.3gp',
  'video/3gpp2' => '.3g2',
  'video/mp2t' => '.ts',
  'video/x-msvideo' => '.avi',
  _ => '.mp4',
};

/// Contadores (sin datos sensibles) para pruebas y logs de depuración.
class StreamServerStats {
  int requests = 0;
  int rejected = 0;
  int responses200 = 0;
  int responses206 = 0;
  int responses416 = 0;
  int heads = 0;

  /// Respuestas cortadas: cliente desconectado, servidor cerrado o bloque
  /// inválido.
  int aborted = 0;
  int integrityFailures = 0;

  /// Bloques descifrados (cada trozo que entrega streamRange).
  int blocksDecrypted = 0;
  int bytesSent = 0;

  /// Respuestas con cuerpo en curso ahora mismo / máximo simultáneo visto.
  int activeBodies = 0;
  int maxActiveBodies = 0;

  /// Bloques en claro retenidos a la vez (máximo visto entre todas las
  /// conexiones). Indicador de memoria acotada.
  int liveBlocks = 0;
  int maxLiveBlocks = 0;
}

/// Servidor HTTP en loopback que sirve UN `.vault` descifrado al vuelo.
class VaultStreamServer {
  VaultStreamServer._(
    this._server,
    this._reader,
    this.mimeType,
    this._path,
    this._closeReader,
    this._onIntegrityFailure,
    this._maxConnections,
  ) : port = _server.port;

  static final Set<VaultStreamServer> _live = {};

  /// Servidores abiertos en este proceso.
  static int get liveCount => _live.length;

  /// Cierra TODOS los servidores ya (síncrono hasta donde es posible): se
  /// engancha a `VaultSession.addOnClear` como red de seguridad del bloqueo.
  static void closeAllNow() {
    for (final s in List.of(_live)) {
      unawaited(s.close());
    }
  }

  final HttpServer _server;
  final VaultFileReader _reader;
  final String mimeType;
  final String _path;
  final bool _closeReader;
  final void Function(VaultCryptoException error)? _onIntegrityFailure;
  final int _maxConnections;
  final Set<Socket> _sockets = {};
  final StreamServerStats stats = StreamServerStats();
  final Stopwatch _uptime = Stopwatch()..start();
  bool _closed = false;
  Future<void>? _closing;
  VaultCryptoException? _poisoned;

  /// Abre el servidor sobre [reader] (abierto con verifyFinal=true para que
  /// la longitud esté autenticada). Por defecto el servidor es dueño del
  /// lector y lo cierra en [close].
  static Future<VaultStreamServer> start({
    required VaultFileReader reader,
    required String mimeType,
    String? extension,
    void Function(VaultCryptoException error)? onIntegrityFailure,
    Random? random,
    bool closeReader = true,
    int maxConnections = 8,
    Duration idleTimeout = const Duration(seconds: 20),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.defaultResponseHeaders.clear();
    server.serverHeader = null;
    server.autoCompress = false;
    server.idleTimeout = idleTimeout;
    final rng = random ?? Random.secure();
    final tokenBytes = Uint8List(32); // 256 bits
    for (var i = 0; i < tokenBytes.length; i++) {
      tokenBytes[i] = rng.nextInt(256);
    }
    final token = base64Url.encode(tokenBytes).replaceAll('=', '');
    final ext = extension ?? videoExtensionFor(mimeType);
    final s = VaultStreamServer._(
      server,
      reader,
      mimeType,
      '/v/$token$ext',
      closeReader,
      onIntegrityFailure,
      maxConnections,
    );
    _live.add(s);
    server.listen(
      (req) => unawaited(s._handle(req)),
      onError: (Object _) {},
      cancelOnError: false,
    );
    return s;
  }

  /// Puerto efímero asignado por el SO (se conserva tras cerrar).
  final int port;
  bool get isClosed => _closed;

  /// Error de integridad que envenenó el servidor (o `null`).
  VaultCryptoException? get integrityFailure => _poisoned;

  /// URL completa (incluye el token: NO registrar en logs).
  Uri get uri => Uri.http('127.0.0.1:$port', _path);

  /// Cierra el servidor, corta las conexiones activas y (si es dueño) cierra
  /// el lector. Idempotente. La parte síncrona (dejar de aceptar y destruir
  /// sockets) ocurre antes del primer `await`.
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    _closed = true;
    _live.remove(this);
    for (final s in List.of(_sockets)) {
      s.destroy();
    }
    _sockets.clear();
    final serverClosed = _server.close(force: true);
    return _closing = () async {
      try {
        await serverClosed;
      } on Object {
        // ya cerrado
      }
      if (_closeReader) {
        try {
          await _reader.close();
        } on Object {
          // ya cerrado
        }
      }
      _log(
        'cerrado tras ${_uptime.elapsedMilliseconds} ms: '
        'peticiones=${stats.requests} 200=${stats.responses200} '
        '206=${stats.responses206} 416=${stats.responses416} '
        'rechazadas=${stats.rejected} cortadas=${stats.aborted} '
        'bloques=${stats.blocksDecrypted} bytes=${stats.bytesSent} '
        'maxBloquesVivos=${stats.maxLiveBlocks}',
      );
    }();
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    stats.requests++;
    final res = req.response;
    try {
      if (_closed) return await _empty(res, HttpStatus.serviceUnavailable);
      final remote = req.connectionInfo?.remoteAddress;
      if (remote == null || !remote.isLoopback) {
        return await _empty(res, HttpStatus.forbidden);
      }
      if (!_hostAllowed(req.headers.value(HttpHeaders.hostHeader))) {
        return await _empty(res, HttpStatus.forbidden);
      }
      if (req.uri.hasQuery || !_constantTimeEquals(req.uri.path, _path)) {
        return await _empty(res, HttpStatus.notFound);
      }
      final isHead = req.method == 'HEAD';
      if (!isHead && req.method != 'GET') {
        return await _empty(res, HttpStatus.methodNotAllowed);
      }
      if (_poisoned != null) {
        return await _empty(res, HttpStatus.internalServerError);
      }
      final total = _reader.plaintextLength;
      final range = parseRangeHeader(
        req.headers.value(HttpHeaders.rangeHeader),
        total,
      );
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('x-content-type-options', 'nosniff');
      final int start;
      final int length;
      switch (range) {
        case UnsatisfiableRange():
          stats.responses416++;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          return await _empty(
            res,
            HttpStatus.requestedRangeNotSatisfiable,
            countAsRejected: false,
          );
        case PartialRange():
          start = range.start;
          length = range.length;
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${range.start}-${range.endInclusive}/$total',
          );
        case FullRange():
          start = 0;
          length = total;
          res.statusCode = HttpStatus.ok;
      }
      res.headers.contentType = ContentType.parse(mimeType);
      res.contentLength = length;
      if (isHead || length == 0) {
        if (isHead) stats.heads++;
        _countStatus(res.statusCode);
        await res.close();
        return;
      }
      if (stats.activeBodies >= _maxConnections) {
        res.headers.removeAll(HttpHeaders.contentRangeHeader);
        return await _empty(res, HttpStatus.serviceUnavailable);
      }
      await _sendBody(res, start, length);
    } on Object {
      // Errores de socket del cliente: nada que responder.
      try {
        await res.close();
      } on Object {
        // ignorar
      }
    }
  }

  void _countStatus(int status) {
    if (status == HttpStatus.ok) stats.responses200++;
    if (status == HttpStatus.partialContent) stats.responses206++;
  }

  Future<void> _sendBody(HttpResponse res, int start, int length) async {
    final watch = Stopwatch()..start();
    final status = res.statusCode;
    stats.activeBodies++;
    stats.maxActiveBodies = max(stats.maxActiveBodies, stats.activeBodies);
    final blocks = StreamIterator<Uint8List>(
      _reader.streamRange(start, start + length),
    );
    var held = 0; // bloques en claro retenidos por esta conexión
    void hold(int delta) {
      held += delta;
      stats.liveBlocks += delta;
      stats.maxLiveBlocks = max(stats.maxLiveBlocks, stats.liveBlocks);
    }

    Socket? socket;
    var clientGone = false;
    var sent = 0;
    StreamSubscription<Uint8List>? input;
    try {
      // 1) Primer bloque ANTES de las cabeceras: si no autentica, 500 limpio.
      final Uint8List first;
      try {
        if (!await blocks.moveNext()) {
          throw const VaultFormatException('Rango vacío inesperado');
        }
        first = blocks.current;
        stats.blocksDecrypted++;
        hold(1);
      } on VaultCryptoException catch (e) {
        _poison(e);
        res.headers
          ..removeAll(HttpHeaders.contentRangeHeader)
          ..removeAll(HttpHeaders.contentTypeHeader);
        await _empty(res, HttpStatus.internalServerError);
        return;
      }
      if (_closed) {
        stats.aborted++;
        await _empty(res, HttpStatus.serviceUnavailable);
        return;
      }

      // 2) Cabeceras y socket crudo: así se puede CORTAR la respuesta a mitad
      //    (destroy) si un bloque posterior no autentica.
      _countStatus(status);
      res.persistentConnection = false;
      socket = await res.detachSocket(writeHeaders: true);
      if (_closed) {
        socket.destroy();
        stats.aborted++;
        return;
      }
      _sockets.add(socket);
      // Fin de la lectura = el cliente cerró (seek de ExoPlayer, visor
      // cerrado...). Se deja de descifrar.
      input = socket.listen(
        (_) {},
        onDone: () => clientGone = true,
        onError: (Object _) => clientGone = true,
        cancelOnError: true,
      );

      var chunk = first;
      while (true) {
        // Se descifra el siguiente bloque mientras se envía el actual.
        final next = blocks.moveNext().then((more) {
          if (more) {
            stats.blocksDecrypted++;
            hold(1); // el bloque siguiente ya está en claro en memoria
          }
          return more;
        });
        next.ignore(); // el error (si lo hay) se recoge abajo con await
        socket.add(chunk);
        stats.bytesSent += chunk.length;
        sent += chunk.length;
        await socket.flush(); // contrapresión: no adelantarse al cliente
        hold(-1);
        if (sent < length && (clientGone || _closed)) {
          stats.aborted++;
          break;
        }
        final bool more;
        try {
          more = await next;
        } on VaultCryptoException catch (e) {
          if (!_closed) _poison(e);
          stats.aborted++;
          socket.destroy(); // nunca se envía un byte del bloque inválido
          return;
        }
        if (!more) {
          if (sent == length) await socket.close();
          break;
        }
        chunk = blocks.current;
      }
    } on Object {
      // Cliente desconectado (flush falló), servidor cerrado (lector
      // cerrado) o error de E/S: se corta.
      stats.aborted++;
      socket?.destroy();
    } finally {
      if (held > 0) hold(-held);
      stats.activeBodies--;
      await input?.cancel();
      try {
        await blocks.cancel(); // detiene streamRange: no más descifrado
      } on Object {
        // el error ya se contabilizó
      }
      if (socket != null) {
        _sockets.remove(socket);
        socket.destroy();
      }
      _log(
        'respuesta $status ${length}B en '
        '${watch.elapsedMilliseconds} ms',
      );
    }
  }

  void _poison(VaultCryptoException e) {
    if (_poisoned != null) return;
    _poisoned = e;
    stats.integrityFailures++;
    _log('bloque no autentica: servidor envenenado');
    try {
      _onIntegrityFailure?.call(e);
    } on Object {
      // el callback no debe romper el servidor
    }
  }

  Future<void> _empty(
    HttpResponse res,
    int status, {
    bool countAsRejected = true,
  }) async {
    if (countAsRejected) stats.rejected++;
    res.statusCode = status;
    res.headers.contentType = null;
    res.contentLength = 0;
    res.persistentConnection = false;
    await res.close();
  }

  bool _hostAllowed(String? host) {
    if (host == null) return false;
    final h = host.trim().toLowerCase();
    return h == '127.0.0.1:$port' || h == 'localhost:$port';
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < y.length; i++) {
      diff |= (i < x.length ? x[i] : 0) ^ y[i];
    }
    return diff == 0;
  }

  void _log(String msg) {
    if (!kReleaseMode) debugPrint('[vault-stream] $msg');
  }
}
