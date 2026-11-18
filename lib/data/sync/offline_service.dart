import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../core/logging/vault_log.dart';
import '../../core/session/session_ticket.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import 'network_monitor.dart';
import 'sync_preferences.dart';
import 'vault_file_fetcher.dart';

/// "Disponible sin conexión" (F6a): por archivo y por carpeta (hereda a todo
/// el contenido, incluidas subcarpetas).
///
/// * Activar guarda la bandera y descarga en segundo plano lo que falte con
///   una cola de un solo worker, con progreso por item ([progress]) y
///   respetando "solo Wi-Fi" igual que las subidas.
/// * El estado visible: `sin_conexion` mientras la copia local existe y el
///   item es offline efectivo. [reconcile] lo mantiene coherente.
/// * Quitar "sin conexión" NO borra nada: el item vuelve a `en_cache` y pasa
///   a ser purgable por la caché LRU.
/// * Una pasada intenta cada item una vez; se reintenta al volver la red, al
///   desbloquear/arrancar o con [reconcile] manual.
class OfflineService {
  OfflineService({
    required this.items,
    required this.fetcher,
    required this.network,
    required this.prefs,
    required this.isUnlocked,
    this.sessionTicket,
  });

  final VaultDataRepository items;
  final VaultFileFetcher fetcher;
  final NetworkMonitor network;
  final SyncPreferences prefs;
  final bool Function() isUnlocked;

  /// D67 (fase 8): ticket de la sesión de SU bóveda (o `null` si no está
  /// abierta). La pasada y las descargas paran si cambia. `null` (pruebas) =
  /// sin esta guarda.
  final SessionTicket? Function()? sessionTicket;

  /// Progreso 0..1 por id de item mientras se descarga.
  final ValueNotifier<Map<String, double>> progress = ValueNotifier(const {});

  /// Último error por item (mensaje para depurar/UI), vacío si todo bien.
  final Map<String, Object> failures = {};

  final Queue<String> _queue = Queue();
  final Set<String> _queued = {};
  bool _running = false;
  CloudCancelToken? _token;
  StreamSubscription<NetworkKind>? _netSub;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();

  bool get isDownloading => _running;
  int get pendingDownloads => _queue.length;

  /// Escucha la red para reanudar descargas pendientes.
  void start() {
    _netSub ??= network.changes.listen((kind) {
      if (kind.isOnline && isUnlocked()) unawaited(reconcile());
    });
  }

  void dispose() {
    _disposed = true;
    _token?.cancel();
    _netSub?.cancel();
    progress.dispose();
  }

  /// Bloqueo: cancela la descarga en curso y vacía la cola en memoria (se
  /// reconstruye en el próximo [reconcile]).
  void cancel() {
    _token?.cancel();
    _queue.clear();
    _queued.clear();
    if (!_disposed) progress.value = const {};
  }

  // ------------------------------------------------------------ acciones

  /// Marca/desmarca un item. Devuelve `false` si no se pudo marcar (p. ej. no
  /// tiene copia en la nube NI local todavía: se marca igual, ver abajo).
  Future<bool> setItemOffline(String itemId, bool value) async {
    try {
      final item = await items.getItem(itemId);
      if (item == null) return false;
      await items.setItemOffline(itemId, value);
      await reconcile();
      return true;
    } on Object catch (e) {
      VaultLog.e('setItemOffline falló', e);
      return false;
    }
  }

  Future<void> setFolderOffline(String folderId, bool value) async {
    await items.setFolderOffline(folderId, value);
    await reconcile();
  }

  // ---------------------------------------------------------------- reconcile

  /// Sincroniza estados con las banderas (propias/heredadas) y encola las
  /// descargas que falten. Serializado.
  Future<void> reconcile() {
    final run = _tail.then((_) => _reconcile());
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _reconcile() async {
    if (_disposed || !isUnlocked()) return;
    // D67: bóveda y época al empezar; un bloqueo u otra bóveda cortan.
    final ticket = sessionTicket?.call();
    if (sessionTicket != null && ticket == null) return;
    final effective = await items.getEffectiveOfflineItemIds();
    final verified = await items.getCloudVerifiedItems();
    for (final item in verified) {
      if (ticket != null && !ticket.isValid) return;
      final local = fetcher.hasLocal(item);
      if (effective.contains(item.id)) {
        if (local) {
          if (item.syncStatus != SyncStatus.sinConexion) {
            await _setStatus(item, SyncStatus.sinConexion);
          }
        } else {
          _enqueue(item.id);
        }
      } else if (item.syncStatus == SyncStatus.sinConexion) {
        await _setStatus(item, local ? SyncStatus.enCache : SyncStatus.enNube);
      }
    }
    if (_queue.isNotEmpty && !_running) unawaited(_drain());
  }

  Future<void> _setStatus(VaultItemModel item, SyncStatus s) async {
    try {
      await items.updateSyncStatus(item.id, s);
    } on StateError catch (e) {
      if (e.message.contains('bloqueada')) rethrow;
    }
  }

  void _enqueue(String id) {
    if (_queued.add(id)) _queue.add(id);
  }

  // ------------------------------------------------------------------ worker

  Future<bool> _networkAllowed() async {
    final net = await network.current();
    if (!net.isOnline) return false;
    if (net == NetworkKind.mobile && await prefs.getWifiOnly()) return false;
    return true;
  }

  Future<void> _drain() async {
    if (_running || _disposed) return;
    _running = true;
    final token = _token = CloudCancelToken();
    final ticket = sessionTicket?.call();
    try {
      while (_queue.isNotEmpty &&
          !token.isCancelled &&
          isUnlocked() &&
          (sessionTicket == null || (ticket?.isValid ?? false))) {
        if (!await _networkAllowed()) {
          // Sin red / solo Wi-Fi: se queda pendiente hasta que vuelva.
          _queue.clear();
          _queued.clear();
          break;
        }
        final id = _queue.removeFirst();
        _queued.remove(id);
        await _download(id, token);
      }
    } finally {
      _running = false;
      if (!_disposed) progress.value = const {};
    }
  }

  Future<void> _download(String id, CloudCancelToken token) async {
    try {
      final item = await items.getItem(id);
      if (item == null) return;
      if (!await items.isEffectivelyOffline(id)) return; // lo quitaron
      _setProgress(id, 0);
      await fetcher.ensureLocal(
        item,
        cancel: token,
        onProgress: (got, total) =>
            _setProgress(id, total <= 0 ? 0 : got / total),
      );
      failures.remove(id);
    } on CloudCancelledException {
      // bloqueo o cancelación: no es un fallo
    } on StateError {
      // bloqueada / item borrado
    } on Object catch (e) {
      failures[id] = e;
      VaultLog.e('Descarga sin conexión falló', e);
    } finally {
      _setProgress(id, null);
    }
  }

  void _setProgress(String id, double? value) {
    if (_disposed) return;
    final map = Map<String, double>.of(progress.value);
    if (value == null) {
      if (map.remove(id) == null) return;
    } else {
      final old = map[id];
      if (old != null && value < 1 && (value - old).abs() < 0.01) return;
      map[id] = value;
    }
    progress.value = map;
  }

  /// Espera a que termine la descarga en curso (pruebas).
  @visibleForTesting
  Future<void> idle() async {
    await _tail;
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}
