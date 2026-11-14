import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../session/vault_session.dart';
import 'biometric_key_store.dart';
import 'kdf.dart';
import 'key_hierarchy.dart';
import 'key_recovery_service.dart';
import 'pin_attempt_limiter.dart';
import 'secure_kv_store.dart';
import 'wrapped_key.dart';

export 'biometric_key_store.dart'
    show BiometricAvailability, BiometricCancelledException;
export 'pin_attempt_limiter.dart' show PinLockedOutException;

/// Resultado de crear la bóveda.
class VaultCreationResult {
  const VaultCreationResult({
    required this.recoveryCode,
    required this.recoveryBackupJson,
  });

  /// Código de recuperación formateado en grupos ("ABCD-EFGH-..."). Se
  /// muestra UNA vez al usuario y no se guarda en ningún sitio.
  final String recoveryCode;

  /// Respaldo de recuperación serializado (DEK envuelta con KEK_rec). Es
  /// seguro subirlo a Drive appDataFolder (F5).
  final String recoveryBackupJson;
}

/// Orquesta la jerarquía de llaves de la bóveda.
///
/// * DEK: 256 bits aleatorios (`Random.secure`), generada una sola vez.
/// * KEK_pin = Argon2id(PIN, salt) → envuelve la DEK (AES-256-GCM). Solo se
///   guarda en el almacenamiento seguro LOCAL. El PIN nunca protege nada que
///   salga del teléfono.
/// * KEK_rec = Argon2id(código de recuperación, salt2) → envuelve otra copia
///   de la DEK; esa copia es el respaldo exportable.
/// * Biometría: copia de la DEK en un almacén ligado a la biometría del SO.
/// * Subllaves HKDF ("sqlcipher", "files", "thumbs") en [VaultSession].
class AuthController {
  AuthController({
    SecureKeyValueStore? storage,
    BiometricKeyStore? biometricStore,
    Argon2Params kdfParams = Argon2Params.production,
    Clock? clock,
    VaultSession? session,
    Random? random,
  }) : _storage = storage ?? FlutterSecureKeyValueStore(),
       _biometrics = biometricStore ?? SystemBiometricKeyStore(),
       _kdf = kdfParams,
       _session = session ?? VaultSession(),
       _random = random ?? Random.secure() {
    _limiter = PinAttemptLimiter(_storage, clock: clock);
    _recovery = KeyRecoveryService(kdfParams: _kdf, random: _random);
  }

  // Claves en el almacenamiento seguro local.
  static const String pinEnvelopeKey = 'vault.v1.pin_envelope';
  static const String recoveryBackupKey = 'vault.v1.recovery_backup';
  static const String keyCheckKey = 'vault.v1.key_check';
  static const String biometricEnabledKey = 'vault.v1.biometric_enabled';

  static const int minPinLength = 4;

  final SecureKeyValueStore _storage;
  final BiometricKeyStore _biometrics;
  final Argon2Params _kdf;
  final VaultSession _session;
  final Random _random;
  late final PinAttemptLimiter _limiter;
  late final KeyRecoveryService _recovery;

  VaultSession get session => _session;
  bool get isUnlocked => _session.isUnlocked;

  Future<bool> hasVault() async =>
      (await _storage.read(pinEnvelopeKey)) != null;

  // ---------------------------------------------------------------------
  // Creación
  // ---------------------------------------------------------------------

  /// Crea la bóveda: genera la DEK, la envuelve con el PIN y con un código de
  /// recuperación nuevo, y deja la sesión desbloqueada.
  ///
  /// Lanza [StateError] si ya existe una bóveda (la DEK se genera una sola
  /// vez; para reemplazarla usa [restoreFromRecovery]).
  Future<VaultCreationResult> createVault(String pin) async {
    _checkPin(pin);
    if (await hasVault()) {
      throw StateError('Ya existe una bóveda en este dispositivo');
    }

    final dek = randomBytes(32, _random);
    try {
      final code = _recovery.generateRecoveryCode();
      final backup = await _recovery.createBackup(dek, code);
      final pinEnvelope = await _wrapWithPin(dek, pin);
      final keys = await KeyHierarchy.fromDek(dek);

      // Orden: primero lo auxiliar, al final la envoltura del PIN (que es lo
      // que marca que la bóveda existe). Si la app muere a medias, no queda
      // una bóveda "a medio crear".
      final backupJson = backup.toJsonString();
      await _storage.write(recoveryBackupKey, backupJson);
      await _storage.write(keyCheckKey, keys.keyCheck);
      await _storage.delete(biometricEnabledKey);
      await _safeDeleteBiometricKey();
      await _limiter.reset();
      await _storage.write(pinEnvelopeKey, pinEnvelope.encode());

      _session.open(keys);
      return VaultCreationResult(
        recoveryCode: RecoveryCode.format(code),
        recoveryBackupJson: backupJson,
      );
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  // ---------------------------------------------------------------------
  // PIN
  // ---------------------------------------------------------------------

  /// Tiempo de espera restante por PIN incorrectos, o `null`.
  Future<Duration?> pinLockoutRemaining() => _limiter.remainingLockout();

  /// Desbloquea con el PIN. Devuelve `false` si es incorrecto.
  /// Lanza [PinLockedOutException] si hay que esperar.
  Future<bool> unlockWithPin(String pin) async {
    final dek = await _verifyPin(pin);
    if (dek == null) return false;
    try {
      await _openSession(dek);
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  /// Cambia el PIN: verifica el viejo y vuelve a envolver la MISMA DEK con un
  /// salt nuevo. No recifra nada. Devuelve `false` si el PIN viejo es
  /// incorrecto. Lanza [PinLockedOutException] si hay que esperar.
  Future<bool> changePin({
    required String oldPin,
    required String newPin,
  }) async {
    _checkPin(newPin);
    final dek = await _verifyPin(oldPin);
    if (dek == null) return false;
    try {
      final envelope = await _wrapWithPin(dek, newPin);
      await _storage.write(pinEnvelopeKey, envelope.encode());
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  /// Verifica el PIN con conteo pesimista de intentos. Devuelve la DEK.
  Future<Uint8List?> _verifyPin(String pin) async {
    final raw = await _storage.read(pinEnvelopeKey);
    if (raw == null) return null;
    await _limiter.ensureNotLocked();
    // Se cuenta como fallo ANTES de derivar; se resetea si acierta.
    await _limiter.registerFailure();
    final envelope = WrappedKey.decode(raw, expectedPurpose: WrapPurpose.pin);
    final dek = await envelope.unwrap(utf8.encode(pin));
    if (dek == null) return null;
    await _limiter.reset();
    return dek;
  }

  Future<WrappedKey> _wrapWithPin(List<int> dek, String pin) => WrappedKey.wrap(
    dek: dek,
    secret: utf8.encode(pin),
    purpose: WrapPurpose.pin,
    kdf: _kdf,
    random: _random,
  );

  void _checkPin(String pin) {
    if (pin.length < minPinLength) {
      throw ArgumentError('El PIN debe tener al menos $minPinLength dígitos');
    }
  }

  // ---------------------------------------------------------------------
  // Recuperación
  // ---------------------------------------------------------------------

  /// Respaldo de recuperación guardado localmente (para que F5 lo suba).
  Future<String?> exportRecoveryBackup() => _storage.read(recoveryBackupKey);

  /// Restaura la bóveda con el código de recuperación y el respaldo (p. ej.
  /// descargado de Drive) y fija [newPin]. Sirve tanto para "olvidé el PIN"
  /// como para un teléfono nuevo. Reemplaza cualquier bóveda local.
  ///
  /// Devuelve `false` si el código es incorrecto. Lanza [FormatException] si
  /// [recoveryBackupJson] no es un respaldo válido.
  Future<bool> restoreFromRecovery({
    required String recoveryCode,
    required String recoveryBackupJson,
    required String newPin,
  }) async {
    _checkPin(newPin);
    final backup = RecoveryBackup.parse(recoveryBackupJson);
    final dek = await _recovery.recoverDek(recoveryCode, backup);
    if (dek == null) return false;
    try {
      final envelope = await _wrapWithPin(dek, newPin);
      final keys = await KeyHierarchy.fromDek(dek);
      await _storage.write(recoveryBackupKey, backup.toJsonString());
      await _storage.write(keyCheckKey, keys.keyCheck);
      // La copia biométrica podría ser de otra DEK: se descarta.
      await _storage.delete(biometricEnabledKey);
      await _safeDeleteBiometricKey();
      await _limiter.reset();
      await _storage.write(pinEnvelopeKey, envelope.encode());
      _session.open(keys);
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  // ---------------------------------------------------------------------
  // Biometría
  // ---------------------------------------------------------------------

  Future<BiometricAvailability> biometricAvailability() =>
      _biometrics.availability();

  Future<bool> isBiometricUnlockEnabled() async =>
      (await _storage.read(biometricEnabledKey)) == 'true';

  /// Guarda una copia de la DEK en el almacén biométrico del SO. Requiere la
  /// bóveda desbloqueada. Puede lanzar [BiometricCancelledException].
  Future<void> enableBiometricUnlock() async {
    if (await _biometrics.availability() != BiometricAvailability.available) {
      throw StateError('La biometría no está disponible en este dispositivo');
    }
    final dek = _session.keys.dekBytes();
    try {
      await _biometrics.writeKey(dek);
      await _storage.write(biometricEnabledKey, 'true');
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  Future<void> disableBiometricUnlock() async {
    await _storage.delete(biometricEnabledKey);
    await _safeDeleteBiometricKey();
  }

  /// Desbloquea con biometría. Devuelve `false` si no está activada, si el
  /// SO invalidó la llave (cambio de huellas/rostros) o si la DEK no
  /// corresponde a esta bóveda; en esos casos hay que usar el PIN.
  /// Lanza [BiometricCancelledException] si el usuario cancela.
  Future<bool> unlockWithBiometrics() async {
    if (!await isBiometricUnlockEnabled() || !await hasVault()) return false;
    final dek = await _biometrics.readKey();
    if (dek == null || dek.length != 32) {
      // Llave invalidada por el SO: desactivar hasta que se vuelva a activar.
      await disableBiometricUnlock();
      return false;
    }
    try {
      final keys = await KeyHierarchy.fromDek(dek);
      final expected = await _storage.read(keyCheckKey);
      if (expected == null || expected != keys.keyCheck) {
        keys.destroy();
        await disableBiometricUnlock();
        return false;
      }
      _session.open(keys);
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  Future<void> _safeDeleteBiometricKey() async {
    try {
      await _biometrics.deleteKey();
    } catch (_) {
      // Si el SO ya la había invalidado/borrado, no hay nada que hacer.
    }
  }

  // ---------------------------------------------------------------------
  // Sesión
  // ---------------------------------------------------------------------

  Future<void> _openSession(Uint8List dek) async {
    final keys = await KeyHierarchy.fromDek(dek);
    // Autorreparación: versiones sin key_check guardado.
    if (await _storage.read(keyCheckKey) == null) {
      await _storage.write(keyCheckKey, keys.keyCheck);
    }
    _session.open(keys);
  }

  /// Bloquea: destruye las llaves en memoria.
  void lock() => _session.clear();
}
