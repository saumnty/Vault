import 'dart:async';
import 'dart:io';

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
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CloudStorage cloud;
  final VaultDataRepository items;
  final File Function(String relativePath) resolvePath;
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

  Future<File> _ensure(
    VaultItemModel item,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  ) async {
    final target = resolvePath(item.encryptedPath);
    if (await target.exists()) {
      await _touch(item.id);
      return target;
    }
    // Siempre con la fila más reciente (la subida pudo terminar después de
    // cargar la cuadrícula).
    final fresh = await items.getItem(item.id) ?? item;
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
        await items.updateSyncStatus(item.id, status);
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
