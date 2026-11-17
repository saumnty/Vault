import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

/// Un desbloqueo en curso fue cancelado porque se bloqueó la app ([lock])
/// mientras se derivaba la llave: la sesión NO se abre.
class UnlockCancelledException implements Exception {
  const UnlockCancelledException();

  @override
  String toString() => 'Desbloqueo cancelado por bloqueo de la app';
}

/// Llaves recuperadas con el código de recuperación, aún SIN haber escrito
/// nada en el dispositivo (F9). Sirven para abrir la BD descargada y, si todo
/// sale bien, se consolidan con [AuthController.commitRestore]. Si se
/// descartan, [destroy] borra las llaves de memoria.
class RecoveryCandidate {
  RecoveryCandidate._(this.keys, this.backupJson);

  final KeyHierarchy keys;

  /// Respaldo de recuperación tal como estaba en la nube.
  final String backupJson;

  bool _committed = false;

  /// Libera las llaves (no hace nada si ya se consolidaron en la sesión).
  void destroy() {
    if (!_committed) keys.destroy();
  }
}

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
    MonotonicClock? monotonic,
    VaultSession? session,
    Random? random,
  }) : _storage = storage ?? FlutterSecureKeyValueStore(),
       _biometrics = biometricStore ?? SystemBiometricKeyStore(),
       _kdf = kdfParams,
       _session = session ?? VaultSession(),
       _random = random ?? Random.secure() {
    _limiter = PinAttemptLimiter(_storage, clock: clock, monotonic: monotonic);
    _restoreLimiter = PinAttemptLimiter(
      _storage,
      clock: clock,
      monotonic: monotonic,
      key: restoreAttemptsKey,
    );
    _recovery = KeyRecoveryService(kdfParams: _kdf, random: _random);
  }

  // Claves en el almacenamiento seguro local.
  static const String pinEnvelopeKey = 'vault.v1.pin_envelope';
  static const String recoveryBackupKey = 'vault.v1.recovery_backup';
  static const String keyCheckKey = 'vault.v1.key_check';
  static const String biometricEnabledKey = 'vault.v1.biometric_enabled';

  /// Bandera (F8): la bóveda se creó pero el usuario aún no confirmó su
  /// código de recuperación. Mientras exista, al abrir la app se vuelve al
  /// paso del código sin poder saltarse la confirmación.
  static const String onboardingPendingKey = 'vault.v1.onboarding_pending';

  /// Límite de intentos del CÓDIGO de recuperación al restaurar (F9), aparte
  /// del del PIN. Solo frena la interfaz: el respaldo de Drive permite probar
  /// códigos sin conexión (ver D37).
  static const String restoreAttemptsKey = 'vault.v1.restore_attempts';

  /// C1 (D62): la BD de esta bóveda ya se creó. Con la marca escrita,
  /// `VaultDatabase` se niega a crear una BD vacía si falta el archivo. Se
  /// borra al crear o restaurar una bóveda y con [discardLocalKeys].
  static const String dbCreatedKey = 'vault.v1.db_created';

  /// Mínimo para DESBLOQUEAR (acepta PIN de 4 dígitos de bóvedas creadas antes
  /// de S-06). Un PIN NUEVO exige [minNewPinLength].
  static const int minPinLength = 4;

  /// S-06: mínimo de dígitos al crear, cambiar o restaurar el PIN.
  static const int minNewPinLength = 6;

  final SecureKeyValueStore _storage;
  final BiometricKeyStore _biometrics;
  final Argon2Params _kdf;
  final VaultSession _session;
  final Random _random;
  late final PinAttemptLimiter _limiter;
  late final PinAttemptLimiter _restoreLimiter;
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
  /// Con [onboardingPending] se persiste la bandera [onboardingPendingKey]
  /// ANTES de la envoltura del PIN (si el proceso muere a medias no hay
  /// bóveda sin bandera). Se borra con [completeOnboarding].
  ///
  /// Lanza [StateError] si ya existe una bóveda (la DEK se genera una sola
  /// vez; para reemplazarla usa [restoreFromRecovery]).
  Future<VaultCreationResult> createVault(
    String pin, {
    bool onboardingPending = false,
  }) async {
    _checkPin(pin);
    return _serialized(() => _createVault(pin, onboardingPending));
  }

  Future<VaultCreationResult> _createVault(
    String pin,
    bool onboardingPending,
  ) async {
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
      // Una marca de una bóveda anterior impediría crear la BD de ésta.
      await _storage.delete(dbCreatedKey);
      await _safeDeleteBiometricKey();
      await _limiter.reset();
      if (onboardingPending) {
        await _storage.write(onboardingPendingKey, 'true');
      } else {
        await _storage.delete(onboardingPendingKey);
      }
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

  /// iOS (F9): el Keychain sobrevive a desinstalar la app pero los archivos
  /// no. Si hay envoltura del PIN pero la BD local no existe, es una
  /// instalación limpia con restos del Keychain: se olvidan las llaves
  /// locales para poder crear o restaurar una bóveda. Los datos de ESA
  /// bóveda ya no existen en este teléfono (viven en Drive).
  Future<void> discardLocalKeys() async {
    for (final k in [
      pinEnvelopeKey,
      recoveryBackupKey,
      keyCheckKey,
      biometricEnabledKey,
      onboardingPendingKey,
      PinAttemptLimiter.storageKey,
      restoreAttemptsKey,
      dbCreatedKey,
    ]) {
      await _storage.delete(k);
    }
    await _safeDeleteBiometricKey();
  }

  /// C1 (D62): la BD de esta bóveda ya está en disco (restauración instalada).
  /// Desde aquí, si el archivo faltara, no se crearía una BD vacía.
  Future<void> markDatabaseCreated() => _storage.write(dbCreatedKey, 'true');

  /// `true` si falta confirmar el código de recuperación (ver
  /// [onboardingPendingKey]).
  Future<bool> isOnboardingPending() async =>
      (await _storage.read(onboardingPendingKey)) == 'true';

  /// El usuario confirmó su código: se acabó el onboarding obligatorio.
  Future<void> completeOnboarding() => _storage.delete(onboardingPendingKey);

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
    // Un unlock lanzado ANTES de un bloqueo está cancelado: no se fusiona.
    if (inFlight != null &&
        _pinUnlockInFlightPin == pin &&
        _pinUnlockInFlightGen == _lockGeneration) {
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
    final gen = _lockGeneration;
    final future = _serialized(() => _unlockWithPin(pin, id, gen));
    _pinUnlockInFlight = future;
    _pinUnlockInFlightGen = gen;
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

  Future<bool> _unlockWithPin(String pin, int id, int gen) async {
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
        await _openSession(dek, gen);
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
  int _pinUnlockInFlightGen = 0;

  /// Contador de generación de bloqueos: cada [lock] lo incrementa. Un
  /// desbloqueo capturó el valor al empezar y, si cambió al terminar la
  /// derivación, descarta las llaves y no abre la sesión.
  int _lockGeneration = 0;
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
    if (pin.length < minNewPinLength) {
      throw ArgumentError(
        'El PIN debe tener al menos $minNewPinLength dígitos',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Recuperación
  // ---------------------------------------------------------------------

  /// Respaldo de recuperación guardado localmente (para que F5 lo suba).
  Future<String?> exportRecoveryBackup() => _storage.read(recoveryBackupKey);

  /// Genera un código de recuperación NUEVO (F8): verifica [pin], vuelve a
  /// envolver la MISMA DEK con KEK_rec' = Argon2id(código nuevo, salt2
  /// nuevo) y reemplaza el respaldo local. El código viejo deja de abrir el
  /// respaldo local; la DEK, los archivos y la envoltura del PIN no cambian.
  /// El respaldo de Drive se actualiza solo: `SyncService` compara el SHA-256
  /// del respaldo local con el último subido y re-encola la subida.
  ///
  /// Devuelve el código nuevo formateado (grupos de 4) para mostrarlo UNA vez,
  /// o `null` si el PIN es incorrecto. Lanza [PinLockedOutException] si hay
  /// que esperar.
  Future<String?> regenerateRecoveryCode(String pin) {
    return _serialized(() async {
      final dek = await _verifyPin(pin, ++_attemptSeq);
      if (dek == null) return null;
      try {
        final code = _recovery.generateRecoveryCode();
        final backup = await _recovery.createBackup(dek, code);
        await _storage.write(recoveryBackupKey, backup.toJsonString());
        return RecoveryCode.format(code);
      } finally {
        dek.fillRange(0, dek.length, 0);
      }
    });
  }

  /// Restaura la bóveda con el código de recuperación y el respaldo (p. ej.
  /// descargado de Drive) y fija [newPin]. Sirve tanto para "olvidé el PIN"
  /// como para un teléfono nuevo. Reemplaza cualquier bóveda local.
  ///
  /// Devuelve `false` si el código es incorrecto. Lanza [FormatException] si
  /// [recoveryBackupJson] no es un respaldo válido.
  ///
  /// S-19: la app NO usa este método (restaura por `RestoreService`, que sí
  /// aplica el límite de intentos del código). Se conserva solo como primitiva
  /// de pruebas: no aplica límite de intentos, no lo uses en la interfaz.
  @visibleForTesting
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
      final keys = await KeyHierarchy.fromDek(dek);
      await _commit(dek, keys, backup.toJsonString(), newPin);
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  /// Escribe el estado local de una bóveda restaurada. La envoltura del PIN
  /// va ÚLTIMA (es la que marca que la bóveda existe): si algo falla antes,
  /// se deshace lo escrito y no queda una bóveda a medias.
  Future<void> _commit(
    Uint8List dek,
    KeyHierarchy keys,
    String backupJson,
    String newPin,
  ) async {
    try {
      final envelope = await _wrapWithPin(dek, newPin);
      await _storage.write(recoveryBackupKey, backupJson);
      await _storage.write(keyCheckKey, keys.keyCheck);
      // La copia biométrica podría ser de otra DEK: se descarta.
      await _storage.delete(biometricEnabledKey);
      await _storage.delete(onboardingPendingKey);
      // Marca de una bóveda anterior: la de ésta la escribe la instalación
      // (RestoreService) o la primera apertura de su BD.
      await _storage.delete(dbCreatedKey);
      await _safeDeleteBiometricKey();
      await _limiter.reset();
      await _storage.write(pinEnvelopeKey, envelope.encode());
    } catch (_) {
      await _storage.delete(pinEnvelopeKey);
      await _storage.delete(recoveryBackupKey);
      await _storage.delete(keyCheckKey);
      rethrow;
    }
    _session.open(keys);
  }

  /// Tiempo de espera restante por códigos de recuperación incorrectos al
  /// restaurar (F9), o `null`.
  Future<Duration?> restoreLockoutRemaining() =>
      _restoreLimiter.remainingLockout();

  /// F9, paso 1 de una restauración en un teléfono nuevo: deriva KEK_rec y
  /// desenvuelve la DEK con [recoveryBackupJson] SIN escribir nada en el
  /// dispositivo (salvo el contador de intentos). Devuelve las llaves, o
  /// `null` si el código es incorrecto (cuenta como intento fallido).
  ///
  /// Un código con formato inválido (longitud/alfabeto) devuelve `null` sin
  /// contar: ni siquiera llega a la derivación. Lanza [PinLockedOutException]
  /// si hay que esperar y [FormatException] si el respaldo no es válido
  /// (incluida una envoltura con propósito distinto, p. ej. la del PIN).
  ///
  /// El intento se cuenta de forma pesimista (antes de derivar) y se borra al
  /// acertar, igual que el PIN.
  Future<RecoveryCandidate?> verifyRecoveryCode({
    required String recoveryCode,
    required String recoveryBackupJson,
  }) async {
    final backup = RecoveryBackup.parse(recoveryBackupJson);
    if (RecoveryCode.normalize(recoveryCode) == null) return null;
    return _serialized(() async {
      await _restoreLimiter.ensureNotLocked();
      await _restoreLimiter.registerFailure();
      final dek = await _recovery.recoverDek(recoveryCode, backup);
      if (dek == null) return null;
      try {
        final keys = await KeyHierarchy.fromDek(dek);
        await _restoreLimiter.reset();
        return RecoveryCandidate._(keys, recoveryBackupJson);
      } finally {
        dek.fillRange(0, dek.length, 0);
      }
    });
  }

  /// F9, paso final: consolida [candidate] como la bóveda de este
  /// dispositivo con [newPin] (envoltura nueva, la biometría vieja se
  /// descarta) y deja la sesión desbloqueada. Si falla, no queda estado.
  Future<void> commitRestore(RecoveryCandidate candidate, String newPin) {
    _checkPin(newPin);
    return _serialized(() async {
      if (await hasVault()) {
        throw StateError('Ya existe una bóveda en este dispositivo');
      }
      final dek = candidate.keys.dekBytes();
      try {
        await _commit(dek, candidate.keys, candidate.backupJson, newPin);
        candidate._committed = true;
      } finally {
        dek.fillRange(0, dek.length, 0);
      }
    });
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
    final gen = _lockGeneration;
    return _serialized(() => _unlockWithBiometrics(gen));
  }

  Future<bool> _unlockWithBiometrics(int gen) async {
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
      _openChecked(keys, gen);
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  /// Abre la sesión salvo que se haya bloqueado desde que empezó el desbloqueo.
  void _openChecked(KeyHierarchy keys, int gen) {
    if (gen != _lockGeneration) {
      keys.destroy();
      throw const UnlockCancelledException();
    }
    _session.open(keys);
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

  Future<void> _openSession(Uint8List dek, int gen) async {
    final keys = await KeyHierarchy.fromDek(dek);
    // Autorreparación: versiones sin key_check guardado.
    if (await _storage.read(keyCheckKey) == null) {
      await _storage.write(keyCheckKey, keys.keyCheck);
    }
    _openChecked(keys, gen);
  }

  /// Bloquea: destruye las llaves en memoria y CANCELA cualquier desbloqueo en
  /// curso (derivación Argon2/biometría): al terminar no abrirá la sesión.
  void lock() {
    _lockGeneration++;
    _session.clear();
  }
}
