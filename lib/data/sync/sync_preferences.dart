import '../../core/crypto/secure_kv_store.dart';

/// Preferencias y marcas de la sincronización (almacén seguro local).
class SyncPreferences {
  SyncPreferences(this._store);

  final SecureKeyValueStore _store;

  static const String wifiOnlyKey = 'sync.v1.wifi_only';
  static const String recoverySha = 'sync.v1.recovery_uploaded_sha256';
  static const String snapshotAtKey = 'sync.v1.snapshot_at';
  static const String uploadsSinceSnapshotKey =
      'sync.v1.uploads_since_snapshot';

  /// Por defecto SOLO Wi-Fi (no gastar datos móviles sin permiso).
  Future<bool> getWifiOnly() async =>
      (await _store.read(wifiOnlyKey)) != 'false';

  Future<void> setWifiOnly(bool value) =>
      _store.write(wifiOnlyKey, value ? 'true' : 'false');

  Future<String?> getRecoveryUploadedSha() => _store.read(recoverySha);
  Future<void> setRecoveryUploadedSha(String sha) =>
      _store.write(recoverySha, sha);

  Future<int?> getSnapshotAt() async =>
      int.tryParse(await _store.read(snapshotAtKey) ?? '');

  Future<int> getUploadsSinceSnapshot() async =>
      int.tryParse(await _store.read(uploadsSinceSnapshotKey) ?? '') ?? 0;

  Future<void> addUpload() async => _store.write(
    uploadsSinceSnapshotKey,
    '${await getUploadsSinceSnapshot() + 1}',
  );

  Future<void> markSnapshotDone(int atMs) async {
    await _store.write(snapshotAtKey, '$atMs');
    await _store.write(uploadsSinceSnapshotKey, '0');
  }
}
