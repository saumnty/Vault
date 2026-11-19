import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/session/session_ticket.dart';
import '../../../data/gallery/photo_saver.dart' show albumNameFor;
import '../../../data/models/vault_item_model.dart';
import '../../../data/repositories/vault_data_repository.dart';
import 'media_exporter.dart';

/// Cómo terminó una pasada del lote.
enum AlbumJobEnd {
  /// Se intentaron todos los pendientes (puede haber errores por archivo).
  completed,

  /// El usuario canceló.
  cancelled,

  /// Permiso de Fotos denegado: no se descifró nada.
  permissionDenied,

  /// Sin espacio libre para el siguiente archivo (los pendientes quedan).
  noSpace,

  /// La bóveda se bloqueó: se abandona sin escribir nada más.
  locked,

  /// iOS no dejó añadir a un álbum ya creado (permiso de solo agregar):
  /// se detiene para no crear álbumes repetidos.
  albumUnsupported,
}

/// Espacio libre en bytes, o `null` si no se sabe (no se bloquea).
typedef AlbumFreeSpace = Future<int?> Function();

/// Un lote «carpeta -> álbum de Fotos» (v2.2).
///
/// * Secuencial, un archivo a la vez: cada uno se descifra a un temporal, se
///   entrega y se borra en `finally` (lo hace [AlbumMediaExporter]); como mucho
///   hay UN temporal en claro vivo.
/// * Pausable, cancelable y reanudable: [start] vuelve a procesar solo lo que
///   no se guardó (fallidos y los no intentados).
/// * Un error en un archivo no detiene el lote.
/// * Estado solo en memoria: no se guarda nada en disco.
class FolderAlbumJob extends ChangeNotifier {
  FolderAlbumJob({
    required this.exporter,
    required this.items,
    required this.album,
    Set<String> alreadySaved = const {},
    this.freeSpace,
    this.sessionTicket,
    this.onSaved,
    this.spaceMargin = 50 * 1024 * 1024,
  }) : _saved = {
         for (final i in items)
           if (alreadySaved.contains(i.id)) i.id,
       };

  final AlbumMediaExporter exporter;
  final List<VaultItemModel> items;
  final String album;
  final AlbumFreeSpace? freeSpace;

  /// Ticket de la sesión al empezar; se compara entre archivos.
  final SessionTicket? Function()? sessionTicket;

  /// Se invoca con el id de cada archivo guardado (estado de la sesión).
  final void Function(String id)? onSaved;

  /// Margen sobre el doble del tamaño del archivo (temporal + copia de Fotos).
  final int spaceMargin;

  final Set<String> _saved;
  final Set<String> _failed = {};
  bool _running = false;
  bool _paused = false;
  bool _cancelled = false;
  bool _permissionAsked = false;
  Completer<void>? _gate;
  AlbumJobEnd? _end;
  int _runTotal = 0;
  int _runDone = 0;
  int _albumCreations = 0;
  double? _fileProgress;

  int get total => items.length;
  int get savedCount => _saved.length;
  int get failedCount => _failed.length;
  Set<String> get savedIds => Set.unmodifiable(_saved);
  Set<String> get failedIds => Set.unmodifiable(_failed);

  /// Los que aún faltan (fallidos o no intentados).
  int get pendingCount => items.length - _saved.length;

  /// Progreso de ESTA pasada: «N de M».
  int get runDone => _runDone;
  int get runTotal => _runTotal;
  bool get isRunning => _running;
  bool get isPaused => _paused;
  AlbumJobEnd? get end => _end;
  double? get fileProgress => _fileProgress;

  /// Pasada pendiente de empezar o de terminar.
  bool get isIdleOrDone => !_running;

  void pause() {
    if (!_running || _paused) return;
    _paused = true;
    notifyListeners();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _gate?.complete();
    _gate = null;
    notifyListeners();
  }

  /// Cancela la pasada en curso (el archivo en vuelo termina o aborta, y su
  /// temporal se borra). Si no corre, no hace nada.
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    _paused = false;
    _gate?.complete();
    _gate = null;
  }

  /// Procesa los pendientes. Completa al terminar la pasada (nunca lanza).
  Future<AlbumJobEnd> start() async {
    if (_running) return _end ?? AlbumJobEnd.completed;
    _running = true;
    _paused = false;
    _cancelled = false;
    _end = null;
    _failed.clear();
    final pending = [
      for (final i in items)
        if (!_saved.contains(i.id)) i,
    ];
    _runTotal = pending.length;
    _runDone = 0;
    _albumCreations = 0;
    final SessionTicket? ticket = sessionTicket?.call();
    notifyListeners();
    var end = AlbumJobEnd.completed;
    try {
      if (sessionTicket != null && ticket == null) {
        end = AlbumJobEnd.locked;
      } else if (pending.isNotEmpty && !_permissionAsked) {
        if (await exporter.requestPermission()) {
          _permissionAsked = true;
        } else {
          end = AlbumJobEnd.permissionDenied;
        }
      }
      if (end == AlbumJobEnd.completed) {
        end = await _loop(pending, ticket);
      }
    } on Object {
      // Un fallo inesperado del lote no debe dejar la UI colgada.
      end = _cancelled ? AlbumJobEnd.cancelled : AlbumJobEnd.completed;
    } finally {
      _running = false;
      _paused = false;
      _fileProgress = null;
      _end = end;
      notifyListeners();
    }
    return end;
  }

  Future<AlbumJobEnd> _loop(
    List<VaultItemModel> pending,
    SessionTicket? ticket,
  ) async {
    for (final item in pending) {
      if (_paused) {
        _gate = Completer<void>();
        notifyListeners();
        await _gate!.future;
      }
      if (_cancelled) return AlbumJobEnd.cancelled;
      if (ticket != null && !ticket.isValid) return AlbumJobEnd.locked;
      if (!await _hasSpaceFor(item)) return AlbumJobEnd.noSpace;
      if (_cancelled) return AlbumJobEnd.cancelled;
      ExportOutcome outcome;
      var created = false;
      try {
        outcome = await exporter.exportToAlbum(
          item,
          album: album,
          onAlbumCreated: () => created = true,
          onProgress: (p) {
            _fileProgress = p.fraction;
          },
        );
      } on Object {
        outcome = ExportOutcome.failed;
      }
      _fileProgress = null;
      switch (outcome) {
        case ExportOutcome.saved:
          _saved.add(item.id);
          _failed.remove(item.id);
          onSaved?.call(item.id);
          if (created && ++_albumCreations > 1) {
            _runDone++;
            notifyListeners();
            return AlbumJobEnd.albumUnsupported;
          }
        case ExportOutcome.cancelledByLock:
          return AlbumJobEnd.locked;
        case ExportOutcome.permissionDenied:
          _permissionAsked = false;
          return AlbumJobEnd.permissionDenied;
        case ExportOutcome.failed || ExportOutcome.unsupported:
          _failed.add(item.id);
      }
      _runDone++;
      notifyListeners();
    }
    return _cancelled ? AlbumJobEnd.cancelled : AlbumJobEnd.completed;
  }

  Future<bool> _hasSpaceFor(VaultItemModel item) async {
    final probe = freeSpace;
    if (probe == null) return true;
    int? free;
    try {
      free = await probe();
    } on Object {
      free = null;
    }
    if (free == null) return true;
    return free >= item.fileSize * 2 + spaceMargin;
  }
}

/// Qué archivos entran en el álbum y qué se guardó ya en ESTA sesión.
///
/// El estado vive solo en memoria y se borra al bloquear ([reset]) o al cerrar
/// la app: tras un reinicio no se sabe qué quedó ya en Fotos (la pantalla lo
/// avisa antes de repetir).
class FolderAlbumService {
  FolderAlbumService({
    required this.repository,
    required this.exporter,
    this.sessionTicket,
    this.freeSpace,
  });

  final VaultDataRepository repository;
  final AlbumMediaExporter exporter;
  final SessionTicket? Function()? sessionTicket;
  final AlbumFreeSpace? freeSpace;

  final Map<String, Set<String>> _savedByFolder = {};
  FolderAlbumJob? _current;

  /// Lote en curso (si lo hay).
  FolderAlbumJob? get current => _current;

  /// Fotos y videos de la carpeta (`includeSubfolders` = también las
  /// subcarpetas). Los de la Papelera no entran.
  Future<List<VaultItemModel>> collect(
    String folderId, {
    bool includeSubfolders = false,
  }) async {
    // Solo consultas que ya excluyen la Papelera (carpetas y archivos).
    final all = <VaultItemModel>[];
    final queue = <String>[folderId];
    final seen = <String>{folderId};
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      all.addAll(await repository.getItemsByFolder(id));
      if (!includeSubfolders) break;
      for (final f in await repository.getFoldersByParent(id)) {
        if (seen.add(f.id)) queue.add(f.id);
      }
    }
    return [
      for (final i in all)
        if (MediaExporter.canExport(i)) i,
    ];
  }

  /// Cuántos de [items] se guardaron ya en esta sesión desde [folderId].
  int alreadySaved(String folderId, List<VaultItemModel> items) {
    final s = _savedByFolder[folderId];
    if (s == null) return 0;
    return items.where((i) => s.contains(i.id)).length;
  }

  /// Crea el lote. [skipSaved] = false repite todo (puede duplicar).
  FolderAlbumJob createJob({
    required String folderId,
    required String folderName,
    required List<VaultItemModel> items,
    bool skipSaved = true,
    int spaceMargin = 50 * 1024 * 1024,
  }) {
    final set = _savedByFolder.putIfAbsent(folderId, () => {});
    if (!skipSaved) set.removeAll(items.map((i) => i.id));
    final job = FolderAlbumJob(
      exporter: exporter,
      items: items,
      album: albumNameFor(folderName),
      alreadySaved: skipSaved ? set : const {},
      freeSpace: freeSpace,
      sessionTicket: sessionTicket,
      onSaved: set.add,
      spaceMargin: spaceMargin,
    );
    _current = job;
    return job;
  }

  /// Bloqueo: cancela el lote en curso y olvida lo guardado.
  void reset() {
    _current?.cancel();
    _current = null;
    _savedByFolder.clear();
  }
}
