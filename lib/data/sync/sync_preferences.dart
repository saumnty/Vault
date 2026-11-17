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

  /// Epoch ms del último cambio de datos (items, carpetas, nombres, offline,
  /// subidas verificadas) que el snapshot subido aún NO incluye. Ausente =
  /// el snapshot de Drive está al día (F9).
  static const String snapshotDirtyAtKey = 'sync.v1.snapshot_dirty_at';

  /// M7 (D61): correo de una cuenta ANTERIOR de un cambio de cuenta (D52) en
  /// la que el usuario decidió conservar los datos. Esa cuenta guarda un
  /// conjunto completo que abre el código de recuperación de entonces; la
  /// rotación de la DEK lo avisa.
  static const String oldAccountKeptKey = 'migration.v1.old_account_kept';

  /// Por defecto SOLO Wi-Fi (no gastar datos móviles sin permiso).
  Future<bool> getWifiOnly() async =>
      (await _store.read(wifiOnlyKey)) != 'false';

  Future<void> setWifiOnly(bool value) =>
      _store.write(wifiOnlyKey, value ? 'true' : 'false');

  Future<String?> getOldAccountKept() => _store.read(oldAccountKeptKey);
  Future<void> setOldAccountKept(String email) =>
      _store.write(oldAccountKeptKey, email);
  Future<void> clearOldAccountKept() => _store.delete(oldAccountKeptKey);

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

  Future<int?> getDirtyAt() async =>
      int.tryParse(await _store.read(snapshotDirtyAtKey) ?? '');

  Future<void> markDirty(int atMs) => _store.write(snapshotDirtyAtKey, '$atMs');

  Future<void> clearDirty() => _store.delete(snapshotDirtyAtKey);

  /// Registra un snapshot subido. [takenAtMs] es el instante en que se TOMÓ
  /// la copia: la marca "sucio" solo se limpia si el último cambio es anterior
  /// (un cambio posterior a la copia exige otro snapshot).
  Future<void> markSnapshotDone(int atMs, {int? takenAtMs}) async {
    await _store.write(snapshotAtKey, '$atMs');
    await _store.write(uploadsSinceSnapshotKey, '0');
    final dirty = await getDirtyAt();
    if (dirty != null && (takenAtMs == null || dirty <= takenAtMs)) {
      await clearDirty();
    }
  }
}
