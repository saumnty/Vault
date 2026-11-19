import 'dart:io';
import 'dart:typed_data';

import '../../core/session/vault_session.dart';
import 'cloud_storage.dart';

export 'cloud_storage.dart' show CloudSlotException;

/// Envoltorio de [CloudStorage] que corta TODA operación con la bóveda
/// secundaria abierta (defensa en profundidad de G2/G4). La comprobación se
/// hace al ENTRAR a cada método: una operación de la principal ya en vuelo
/// (p. ej. el snapshot que se sube tras bloquear, D38/D53) termina sola.
///
/// Con la sesión bloqueada o con la principal abierta se comporta igual que
/// el almacenamiento envuelto (la restauración y el flush tras bloquear
/// funcionan como siempre).
class SlotGuardedCloudStorage implements CloudStorage {
  SlotGuardedCloudStorage(this._inner, {VaultSession? session})
    : _session = session ?? VaultSession();

  final CloudStorage _inner;
  final VaultSession _session;

  /// El almacenamiento real (pruebas).
  CloudStorage get inner => _inner;

  bool get _blocked => _session.isUnlockedAs(VaultSlot.secondary);

  void _guard() {
    if (_blocked) throw const CloudSlotException();
  }

  @override
  String? get currentAccountEmail =>
      _blocked ? null : _inner.currentAccountEmail;

  @override
  String? get currentAccountId => _blocked ? null : _inner.currentAccountId;

  @override
  Future<CloudAccount> signIn() async {
    _guard();
    return _inner.signIn();
  }

  @override
  Future<CloudAccount?> signInSilently() async {
    _guard();
    return _inner.signInSilently();
  }

  @override
  Future<void> signOut() async {
    _guard();
    return _inner.signOut();
  }

  @override
  Future<CloudQuota> getQuota() async {
    _guard();
    return _inner.getQuota();
  }

  @override
  Future<CloudFile> uploadFile({
    required File file,
    required String name,
    String? replaceFileId,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) async {
    _guard();
    return _inner.uploadFile(
      file: file,
      name: name,
      replaceFileId: replaceFileId,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  @override
  Future<CloudFile> uploadBytes({
    required Uint8List bytes,
    required String name,
    String? replaceFileId,
  }) async {
    _guard();
    return _inner.uploadBytes(
      bytes: bytes,
      name: name,
      replaceFileId: replaceFileId,
    );
  }

  @override
  Future<CloudFile> getMetadata(String fileId) async {
    _guard();
    return _inner.getMetadata(fileId);
  }

  @override
  Future<CloudFile> rename(String fileId, String newName) async {
    _guard();
    return _inner.rename(fileId, newName);
  }

  @override
  Future<void> download(
    String fileId,
    File destination, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
    int? maxBytes,
  }) async {
    _guard();
    return _inner.download(
      fileId,
      destination,
      onProgress: onProgress,
      cancel: cancel,
      maxBytes: maxBytes,
    );
  }

  @override
  Future<Uint8List> downloadBytes(String fileId, {int? maxBytes}) async {
    _guard();
    return _inner.downloadBytes(fileId, maxBytes: maxBytes);
  }

  @override
  Future<void> delete(String fileId) async {
    _guard();
    return _inner.delete(fileId);
  }

  @override
  Future<CloudFile?> findByName(String name) async {
    _guard();
    return _inner.findByName(name);
  }

  @override
  Future<List<CloudFile>> list() async {
    _guard();
    return _inner.list();
  }
}
