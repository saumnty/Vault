import 'dart:async';
import 'dart:io';

import '../../core/crypto/crypto_service.dart';
import '../../core/session/session_ticket.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import 'sync_service.dart' show md5OfFile;

/// No hay de dónde obtener el `.vault`: no existe localmente y el item no
/// tiene una copia verificada en la nube.
class VaultFetchUnavailableException implements Exception {
  const VaultFetchUnavailableException([
    this.message = 'No hay una copia disponible de este archivo',
  ]);
  final String message;
  @override
  String toString() => 'VaultFetchUnavailableException: $message';
}

/// La copia descargada no coincide con el tamaño/MD5 verificados al subir.
class VaultFetchVerificationException implements Exception {
  const VaultFetchVerificationException(this.detail);
  final String detail;
  @override
  String toString() => 'VaultFetchVerificationException: $detail';
}

/// Garantiza que el `.vault` cifrado de un item esté en el dispositivo:
/// si falta (caché purgada, `en_nube`), lo descarga de Drive, VERIFICA
/// tamaño y MD5 contra `cloudSize`/`cloudMd5`, lo guarda en `vault/`, marca
/// `en_cache` (o `sin_conexion` si es offline efectivo) y actualiza
/// `lastAccessedAt`.
///
/// Las peticiones concurrentes por el mismo item comparten una sola descarga.
class VaultFileFetcher {
  VaultFileFetcher({
    required this.cloud,
    required this.items,
    required this.resolvePath,
    int Function()? nowMs,
    this.sessionTicket,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CloudStorage cloud;
  final VaultDataRepository items;
  final File Function(String relativePath) resolvePath;

  /// D67 (fase 8): ticket de la sesión de SU bóveda (o `null` si no está
  /// abierta). Se captura al empezar la descarga y se comprueba antes de
  /// dejar el `.vault` en su sitio y de marcar la fila. `null` (pruebas) =
  /// sin esta guarda.
  final SessionTicket? Function()? sessionTicket;
  final int Function() _now;

  final Map<String, Future<File>> _inFlight = {};

  /// `true` si la copia local existe.
  bool hasLocal(VaultItemModel item) =>
      resolvePath(item.encryptedPath).existsSync();

  /// Devuelve el `.vault` local, descargándolo si hace falta.
  ///
  /// Lanza [VaultFetchUnavailableException], [VaultFetchVerificationException]
  /// o una [CloudException] (sin red, sin sesión, 404, cancelado...).
  Future<File> ensureLocal(
    VaultItemModel item, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) {
    final running = _inFlight[item.id];
    if (running != null) return running;
    final future = _ensure(item, onProgress, cancel);
    _inFlight[item.id] = future;
    return future.whenComplete(() => _inFlight.remove(item.id));
  }

  /// La fila más reciente de [item] (o [item] si ya no existe). La cuadrícula
  /// puede tener un modelo viejo: la subida pudo terminar después, o una
  /// rotación de la DEK pudo pasar el item a otra generación (otra ruta,
  /// otro `fileId`, otra llave; D60).
  Future<VaultItemModel> refresh(VaultItemModel item) async =>
      await items.getItem(item.id) ?? item;

  Future<File> _ensure(
    VaultItemModel item,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  ) async {
    final provider = sessionTicket;
    final SessionTicket? ticket = provider?.call();
    if (provider != null && ticket == null) {
      throw StateError('La bóveda está bloqueada');
    }
    // Siempre con la fila más reciente (ruta y generación actuales).
    final fresh = await refresh(item);
    final target = resolvePath(fresh.encryptedPath);
    if (await target.exists()) {
      await _touch(fresh.id);
      return target;
    }
    final driveId = fresh.driveFileId;
    final md5 = fresh.cloudMd5;
    final size = fresh.cloudSize;
    if (driveId == null || md5 == null || size == null) {
      throw const VaultFetchUnavailableException();
    }
    if (!target.parent.existsSync()) target.parent.createSync(recursive: true);
    final part = File('${target.path}.part');
    try {
      if (await part.exists()) await part.delete();
      await cloud.download(
        driveId,
        part,
        // Drive no siempre informa la longitud (descarga por chunks): se usa
        // el tamaño verificado al subir para que la barra sea determinada.
        onProgress: onProgress == null
            ? null
            : (got, total) => onProgress(got, total > 0 ? total : size),
        cancel: cancel,
      );
      final got = await part.length();
      if (got != size) {
        throw VaultFetchVerificationException(
          'tamaño descargado $got, esperado $size',
        );
      }
      final gotMd5 = await md5OfFile(part);
      if (gotMd5.toLowerCase() != md5.toLowerCase()) {
        throw const VaultFetchVerificationException('MD5 distinto');
      }
      // S-09: el .vault descargado debe ser EL de este item (fileId del
      // encabezado == el registrado), no otro archivo auténtico de la bóveda.
      final expectedId = fresh.fileId;
      if (expectedId != null) {
        final String gotId;
        try {
          gotId = await CryptoService.fileIdOfFile(part);
        } on Object {
          throw const VaultFetchVerificationException(
            'encabezado .vault ilegible',
          );
        }
        if (gotId != expectedId) {
          throw const VaultFetchVerificationException(
            'el archivo no corresponde a este elemento (fileId)',
          );
        }
      }
      ticket?.check(); // D67: el `.part` se borra abajo
      await part.rename(target.path);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } on FileSystemException {
        // se limpiará luego
      }
      rethrow;
    }
    final offline = await items.isEffectivelyOffline(fresh.id);
    ticket?.check();
    await _markLocal(
      fresh,
      offline ? SyncStatus.sinConexion : SyncStatus.enCache,
    );
    return target;
  }

  Future<void> _markLocal(VaultItemModel item, SyncStatus status) async {
    try {
      // Solo estados "de nube": nunca pisar pendiente/subiendo/error.
      if (item.syncStatus == SyncStatus.enNube ||
          item.syncStatus == SyncStatus.enCache ||
          item.syncStatus == SyncStatus.sinConexion) {
        // M4: condicional. Si la fila cambió durante la descarga (otra
        // generación u otra ruta), no se pisa su estado.
        await items.updateSyncStatusIf(
          item.id,
          status,
          expectKeyGen: item.keyGen,
          expectPath: item.encryptedPath,
        );
      }
      await items.touchLastAccessed(item.id, at: _nowDate());
    } on StateError catch (e) {
      if (e.message.contains('bloqueada')) rethrow; // item borrado: se ignora
    }
  }

  Future<void> _touch(String id) async {
    try {
      await items.touchLastAccessed(id, at: _nowDate());
    } on StateError catch (e) {
      if (e.message.contains('bloqueada')) rethrow;
    }
  }

  DateTime _nowDate() => DateTime.fromMillisecondsSinceEpoch(_now());
}
