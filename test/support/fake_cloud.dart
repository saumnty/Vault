import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_service.dart';

class _Blob {
  _Blob(this.id, this.name, this.bytes, this.md5);
  final String id;
  final String name;
  Uint8List bytes;
  String md5;
}

/// [CloudStorage] en memoria con fallos inyectables.
class FakeCloudStorage implements CloudStorage {
  String? email;
  final Map<String, _Blob> _blobs = {};
  int _next = 1;

  /// Pausa por chunk de 64 KiB al subir (para probar cancelación/concurrencia).
  Duration chunkDelay = Duration.zero;

  /// Si no es null, se lanza (una vez) al intentar la operación indicada
  /// ('upload', 'find', 'bytes', 'meta', 'quota', 'list', 'delete').
  Object? Function(String op)? failure;

  /// Lanza [failAfterBytesError] cuando se hayan enviado estos bytes (una vez).
  int? failAfterBytes;
  Object failAfterBytesError = const CloudNoNetworkException();

  /// La próxima subida guarda un MD5 incorrecto (simula corrupción).
  bool corruptNextUpload = false;

  /// La próxima subida guarda menos bytes (tamaño distinto).
  bool truncateNextUpload = false;

  CloudQuota quotaValue = const CloudQuota(usedBytes: 100, limitBytes: 1000);

  final List<String> uploadedNames = [];
  int _active = 0;
  int maxConcurrentUploads = 0;
  int uploadCalls = 0;

  FakeCloudStorage({this.email = 'test@example.com'});

  void _check(String op) {
    final f = failure?.call(op);
    if (f != null) throw f;
  }

  Iterable<String> get names => _blobs.values.map((b) => b.name);
  int get count => _blobs.length;

  CloudFile? byName(String name) {
    for (final b in _blobs.values) {
      if (b.name == name) return _meta(b);
    }
    return null;
  }

  Uint8List? bytesOf(String name) {
    for (final b in _blobs.values) {
      if (b.name == name) return b.bytes;
    }
    return null;
  }

  /// Altera el contenido remoto (simula corrupción/cambio externo).
  void tamper(String id) {
    final b = _blobs[id]!;
    b.bytes = Uint8List.fromList([...b.bytes, 1]);
    b.md5 = 'deadbeef';
  }

  /// Cambia un byte conservando el tamaño (solo el MD5 lo delata).
  void corruptContent(String id) {
    final b = _blobs[id]!;
    final copy = Uint8List.fromList(b.bytes);
    copy[0] = copy[0] ^ 0xff;
    b
      ..bytes = copy
      ..md5 = md5OfBytes(copy);
  }

  void remove(String id) => _blobs.remove(id);

  CloudFile _meta(_Blob b) => CloudFile(
    id: b.id,
    name: b.name,
    size: b.bytes.length,
    md5Checksum: b.md5,
  );

  CloudFile _store(
    String name,
    Uint8List bytes,
    String? replaceId, {
    bool corrupt = false,
  }) {
    final md5 = corrupt
        ? 'ffffffffffffffffffffffffffffffff'
        : md5OfBytes(bytes);
    if (replaceId != null) {
      final b = _blobs[replaceId];
      if (b == null) throw const CloudNotFoundException();
      b
        ..bytes = bytes
        ..md5 = md5;
      return _meta(b);
    }
    final b = _Blob('id${_next++}', name, bytes, md5);
    _blobs[b.id] = b;
    return _meta(b);
  }

  @override
  String? get currentAccountEmail => email;

  @override
  Future<CloudAccount> signIn() async {
    _check('signin');
    email = 'test@example.com';
    return CloudAccount(email: email!);
  }

  @override
  Future<CloudAccount?> signInSilently() async =>
      email == null ? null : CloudAccount(email: email!);

  @override
  Future<void> signOut() async => email = null;

  void _requireAuth() {
    if (email == null) throw const CloudNotAuthenticatedException();
  }

  @override
  Future<CloudQuota> getQuota() async {
    _requireAuth();
    _check('quota');
    return quotaValue;
  }

  @override
  Future<CloudFile> uploadFile({
    required File file,
    required String name,
    String? replaceFileId,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) async {
    _requireAuth();
    _check('upload');
    uploadCalls++;
    _active++;
    if (_active > maxConcurrentUploads) maxConcurrentUploads = _active;
    try {
      final total = await file.length();
      final out = BytesBuilder(copy: false);
      var sent = 0;
      await for (final chunk in file.openRead()) {
        for (var i = 0; i < chunk.length; i += 65536) {
          final end = (i + 65536 < chunk.length) ? i + 65536 : chunk.length;
          if (cancel?.isCancelled ?? false) {
            throw const CloudCancelledException();
          }
          out.add(chunk.sublist(i, end));
          sent += end - i;
          onProgress?.call(sent, total);
          if (chunkDelay > Duration.zero) {
            await Future<void>.delayed(chunkDelay);
          }
          if (failAfterBytes != null && sent >= failAfterBytes!) {
            failAfterBytes = null;
            throw failAfterBytesError;
          }
        }
      }
      var bytes = out.takeBytes();
      if (truncateNextUpload) {
        truncateNextUpload = false;
        bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
      }
      final corrupt = corruptNextUpload;
      corruptNextUpload = false;
      uploadedNames.add(name);
      return _store(name, bytes, replaceFileId, corrupt: corrupt);
    } finally {
      _active--;
    }
  }

  @override
  Future<CloudFile> uploadBytes({
    required Uint8List bytes,
    required String name,
    String? replaceFileId,
  }) async {
    _requireAuth();
    _check('upload');
    uploadedNames.add(name);
    return _store(name, Uint8List.fromList(bytes), replaceFileId);
  }

  @override
  Future<CloudFile> getMetadata(String fileId) async {
    _requireAuth();
    _check('meta');
    final b = _blobs[fileId];
    if (b == null) throw const CloudNotFoundException();
    return _meta(b);
  }

  @override
  Future<void> download(
    String fileId,
    File destination, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) async {
    await destination.writeAsBytes(await downloadBytes(fileId));
  }

  @override
  Future<Uint8List> downloadBytes(String fileId) async {
    _requireAuth();
    _check('bytes');
    final b = _blobs[fileId];
    if (b == null) throw const CloudNotFoundException();
    return b.bytes;
  }

  @override
  Future<void> delete(String fileId) async {
    _requireAuth();
    _check('delete');
    if (_blobs.remove(fileId) == null) throw const CloudNotFoundException();
  }

  @override
  Future<CloudFile?> findByName(String name) async {
    _requireAuth();
    _check('find');
    return byName(name);
  }

  @override
  Future<List<CloudFile>> list() async {
    _requireAuth();
    _check('list');
    return _blobs.values.map(_meta).toList();
  }
}

/// Red simulada.
class FakeNetworkMonitor implements NetworkMonitor {
  FakeNetworkMonitor([this.kind = NetworkKind.wifi]);
  NetworkKind kind;
  final _ctrl = StreamController<NetworkKind>.broadcast();

  void set(NetworkKind k) {
    kind = k;
    _ctrl.add(k);
  }

  @override
  Future<NetworkKind> current() async => kind;

  @override
  Stream<NetworkKind> get changes => _ctrl.stream;
}
