import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../session/vault_session.dart';
import 'biometric_key_store.dart';
import 'crypto_debug.dart';
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
    return _serialized(() => _createVault(pin));
  }

  Future<VaultCreationResult> _createVault(String pin) async {
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
  /// Lanza [PinLockedOutException] si hay que esperar y [StateError] si no
  /// hay bóveda (no es un "PIN incorrecto").
  ///
  /// Concurrencia: si ya hay un desbloqueo con el MISMO PIN en vuelo (doble
  /// toque, auto-envío del último dígito + botón), se devuelve ese mismo
  /// resultado: no se deriva dos veces ni cuenta como otro intento. Cualquier
  /// otra operación de llaves espera su turno ([_serialized]), así el
  /// contador de intentos nunca se lee y escribe a la vez.
  Future<bool> unlockWithPin(String pin) {
    final inFlight = _pinUnlockInFlight;
    if (inFlight != null && _pinUnlockInFlightPin == pin) {
      cryptoDebugLog(
        'unlock#${_attemptSeq + 1}: ignorado, unlock#$_pinUnlockInFlightId '
        'con el mismo PIN ya en vuelo',
      );
      return inFlight;
    }
    final id = ++_attemptSeq;
    if (inFlight != null || _busy) {
      cryptoDebugLog('unlock#$id: hay otra operación en vuelo; se encola');
    }
    final future = _serialized(() => _unlockWithPin(pin, id));
    _pinUnlockInFlight = future;
    _pinUnlockInFlightPin = pin;
    _pinUnlockInFlightId = id;
    void clear() {
      if (identical(_pinUnlockInFlight, future)) {
        _pinUnlockInFlight = null;
        _pinUnlockInFlightPin = null;
        _pinUnlockInFlightId = null;
      }
    }

    future.then((_) => clear(), onError: (Object _) => clear());
    return future;
  }

  Future<bool> _unlockWithPin(String pin, int id) async {
    final sw = Stopwatch()..start();
    cryptoDebugLog('unlock#$id: inicio (${pin.length} dígitos)');
    try {
      final dek = await _verifyPin(pin, id);
      if (dek == null) {
        cryptoDebugLog(
          'unlock#$id: fin INCORRECTO (${sw.elapsedMilliseconds} ms)',
        );
        return false;
      }
      try {
        await _openSession(dek);
        cryptoDebugLog('unlock#$id: fin OK (${sw.elapsedMilliseconds} ms)');
        return true;
      } finally {
        dek.fillRange(0, dek.length, 0);
      }
    } catch (e) {
      cryptoDebugLog(
        'unlock#$id: fin ERROR ${e.runtimeType} (${sw.elapsedMilliseconds} ms)',
      );
      rethrow;
    }
  }

  // Desbloqueo por PIN en vuelo (para fusionar duplicados).
  Future<bool>? _pinUnlockInFlight;
  String? _pinUnlockInFlightPin;
  int? _pinUnlockInFlightId;
  int _attemptSeq = 0;

  // Cola de operaciones de llaves: una a la vez por controlador.
  Future<void> _queue = Future<void>.value();
  bool _busy = false;

  Future<T> _serialized<T>(Future<T> Function() op) {
    final previous = _queue;
    final completer = Completer<void>();
    _queue = completer.future;
    return () async {
      try {
        await previous;
      } catch (_) {}
      _busy = true;
      try {
        return await op();
      } finally {
        _busy = false;
        completer.complete();
      }
    }();
  }

  /// Cambia el PIN: verifica el viejo y vuelve a envolver la MISMA DEK con un
  /// salt nuevo. No recifra nada. Devuelve `false` si el PIN viejo es
  /// incorrecto. Lanza [PinLockedOutException] si hay que esperar.
  Future<bool> changePin({
    required String oldPin,
    required String newPin,
  }) async {
    _checkPin(newPin);
    return _serialized(() async {
      final dek = await _verifyPin(oldPin, ++_attemptSeq);
      if (dek == null) return false;
      try {
        // ÚNICO flujo (junto con crear/restaurar) que genera un salt nuevo
        // para la envoltura del PIN.
        final envelope = await _wrapWithPin(dek, newPin);
        await _storage.write(pinEnvelopeKey, envelope.encode());
        return true;
      } finally {
        dek.fillRange(0, dek.length, 0);
      }
    });
  }

  /// Verifica el PIN con conteo pesimista de intentos. Devuelve la DEK.
  /// Debe llamarse dentro de [_serialized].
  Future<Uint8List?> _verifyPin(String pin, int id) async {
    final raw = await _storage.read(pinEnvelopeKey);
    if (raw == null) {
      // Antes devolvía null y la UI mostraba "PIN incorrecto" aunque el PIN
      // fuera correcto. Sin envoltura no hay nada que verificar.
      cryptoDebugLog('unlock#$id: NO hay envoltura del PIN guardada');
      throw StateError('No hay bóveda en este dispositivo');
    }
    await _limiter.ensureNotLocked();
    // Se cuenta como fallo ANTES de derivar; se resetea si acierta.
    await _limiter.registerFailure();
    final envelope = WrappedKey.decode(raw, expectedPurpose: WrapPurpose.pin);
    cryptoDebugLog(
      'unlock#$id: envoltura salt#=${fingerprint(envelope.salt)} '
      'env#=${fingerprint(utf8.encode(raw))} '
      'kdf=m${envelope.kdf.memoryKiB}/t${envelope.kdf.iterations}'
      '/p${envelope.kdf.parallelism}',
    );
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
    return _serialized(() => _restore(recoveryCode, backup, newPin));
  }

  Future<bool> _restore(
    String recoveryCode,
    RecoveryBackup backup,
    String newPin,
  ) async {
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
  Future<bool> unlockWithBiometrics() {
    if (_busy) {
      cryptoDebugLog('biometría: hay otra operación en vuelo; se encola');
    }
    return _serialized(_unlockWithBiometrics);
  }

  Future<bool> _unlockWithBiometrics() async {
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
