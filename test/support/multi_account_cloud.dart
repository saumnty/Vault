import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault/data/cloud/cloud_storage.dart';

import 'fake_cloud.dart';

/// Nube falsa con VARIAS cuentas de Google (cada una con su propio
/// appDataFolder) y una sola sesión a la vez, como la app real.
///
/// [signInQueue] hace de "selector de cuentas": cada `signIn()` toma el
/// siguiente correo; si está vacía, el usuario "canceló" el selector. Los
/// ayudantes de [FakeCloudStorage] (`names`, `byName`...) de ESTA instancia no
/// se usan: pide la cuenta con [account].
class MultiAccountCloud extends FakeCloudStorage {
  MultiAccountCloud(String initial)
    : _current = initial,
      super(email: initial) {
    account(initial);
  }

  final Map<String, FakeCloudStorage> _accounts = {};
  String? _current;

  /// Correos que devolverá el selector, en orden.
  final List<String> signInQueue = [];
  int signInCalls = 0;
  int signOutCalls = 0;

  FakeCloudStorage account(String email) => _accounts.putIfAbsent(
    email,
    () =>
        FakeCloudStorage(email: email)
          ..quotaValue = const CloudQuota(usedBytes: 0, limitBytes: 1 << 40),
  );

  FakeCloudStorage get _cur {
    final e = _current;
    if (e == null) throw const CloudNotAuthenticatedException();
    return account(e);
  }

  @override
  String? get currentAccountEmail => _current;

  /// D78: el próximo `signIn()` no termina hasta que se complete (selector de
  /// Google colgado, iOS). Al completarlo con un correo, la sesión pasa a esa
  /// cuenta (como un selector que responde tarde).
  Completer<String>? hangNext;

  /// D78: cuántos `signIn()` siguientes se «cancelan» antes de usar la cola.
  int cancelNext = 0;

  @override
  Future<CloudAccount> signIn() async {
    signInCalls++;
    final hang = hangNext;
    if (hang != null) {
      hangNext = null;
      final email = await hang.future;
      _current = email;
      account(email);
      return CloudAccount(email: email);
    }
    if (cancelNext > 0) {
      cancelNext--;
      throw const CloudSignInCancelledException();
    }
    if (signInQueue.isEmpty) throw const CloudSignInCancelledException();
    _current = signInQueue.removeAt(0);
    account(_current!);
    return CloudAccount(email: _current!);
  }

  @override
  Future<CloudAccount?> signInSilently() async =>
      _current == null ? null : CloudAccount(email: _current!);

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _current = null;
  }

  @override
  Future<CloudQuota> getQuota() => _cur.getQuota();

  @override
  Future<CloudFile> uploadFile({
    required File file,
    required String name,
    String? replaceFileId,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) => _cur.uploadFile(
    file: file,
    name: name,
    replaceFileId: replaceFileId,
    onProgress: onProgress,
    cancel: cancel,
  );

  @override
  Future<CloudFile> uploadBytes({
    required Uint8List bytes,
    required String name,
    String? replaceFileId,
  }) =>
      _cur.uploadBytes(bytes: bytes, name: name, replaceFileId: replaceFileId);

  @override
  Future<CloudFile> getMetadata(String fileId) => _cur.getMetadata(fileId);

  @override
  Future<void> download(
    String fileId,
    File destination, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
    int? maxBytes,
  }) => _cur.download(
    fileId,
    destination,
    onProgress: onProgress,
    cancel: cancel,
    maxBytes: maxBytes,
  );

  @override
  Future<Uint8List> downloadBytes(String fileId, {int? maxBytes}) =>
      _cur.downloadBytes(fileId, maxBytes: maxBytes);

  @override
  Future<void> delete(String fileId) => _cur.delete(fileId);

  @override
  Future<CloudFile> rename(String fileId, String newName) =>
      _cur.rename(fileId, newName);

  @override
  Future<CloudFile?> findByName(String name) => _cur.findByName(name);

  @override
  Future<List<CloudFile>> list() => _cur.list();
}
