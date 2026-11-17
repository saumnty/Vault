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
import 'key_rotation_store.dart';
import 'pin_attempt_limiter.dart';
import 'secure_kv_store.dart';
import 'wrapped_key.dart';

export 'biometric_key_store.dart'
    show BiometricAvailability, BiometricCancelledException;
export 'key_rotation_store.dart'
    show RotationPhase, RotationReason, RotationRecord, RotationKeyStore;
export 'pin_attempt_limiter.dart' show PinLockedOutException;

/// La operación no está permitida mientras hay una rotación de la DEK
/// registrada (p. ej. cambiar el PIN, M2) o la rotación no está en la fase
/// que la operación exige.
class RotationInProgressException implements Exception {
  const RotationInProgressException([
    this.message = 'Hay un cambio de llave maestra en curso',
  ]);
  final String message;
  @override
  String toString() => 'RotationInProgressException: $message';
}

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
    RotationKeyStore? rotationStore,
  }) : _storage = storage ?? FlutterSecureKeyValueStore(),
       _biometrics = biometricStore ?? SystemBiometricKeyStore(),
       _kdf = kdfParams,
       _session = session ?? VaultSession(),
       _random = random ?? Random.secure(),
       // La app comparte un solo almacén de rotación (y su `record`); con un
       // almacén inyectado (pruebas) se crea uno sobre él.
       _rotation =
           rotationStore ??
           (storage == null
               ? RotationKeyStore.shared
               : RotationKeyStore(storage)) {
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

  /// D60: generación de la DEK vigente (ausente = 1, la bóveda original).
  static const String keyGenKey = 'vault.v1.key_gen';

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
  final RotationKeyStore _rotation;

  /// Llaves de la DEK NUEVA mientras la rotación está en `prepared`..
  /// `freezing` (solo en memoria, nunca en la sesión: hasta congelar, todo lo
  /// nuevo se sigue cifrando con la vieja). Se obtienen al preparar, al
  /// confirmar el código o al desbloquear con el PIN; se destruyen al
  /// bloquear.
  KeyHierarchy? _nextKeys;

  VaultSession get session => _session;

  /// Almacén de la rotación de la DEK (registro y secretos auxiliares).
  RotationKeyStore get rotationStore => _rotation;

  /// `true` si la DEK nueva de la rotación está en memoria (hace falta para
  /// pasar a `reencrypting`; si no, hay que desbloquear con el PIN).
  bool get hasNextKeys => _nextKeys != null && !_nextKeys!.isDestroyed;
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
      // Restos de otra bóveda en el Keychain (iOS): generación y rotación.
      await _storage.delete(keyGenKey);
      await _rotation.clearAll();
      _dropNextKeys();
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
      keyGenKey,
    ]) {
      await _storage.delete(k);
    }
    // A3: también todo lo de una rotación de la DEK (el registro y la DEK
    // nueva envuelta con el PIN viejo sobreviven en el Keychain de iOS).
    await _rotation.clearAll();
    _dropNextKeys();
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
        await _openSession(dek, gen, pin: pin);
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
  ///
  /// M2 (D63): PROHIBIDO mientras exista una rotación de la DEK (lanza
  /// [RotationInProgressException] sin verificar el PIN ni contar intento):
  /// hay dos envolturas con el PIN y un corte entre las dos dejaría un PIN
  /// distinto del que el usuario cree tener.
  Future<bool> changePin({
    required String oldPin,
    required String newPin,
  }) async {
    _checkPin(newPin);
    return _serialized(() async {
      await _requireNoRotation();
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
  ///
  /// Prohibido durante una rotación de la DEK ([RotationInProgressException]):
  /// reemplazaría el respaldo local que la rotación gestiona.
  Future<String?> regenerateRecoveryCode(String pin) {
    return _serialized(() async {
      await _requireNoRotation();
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
    String newPin, {
    int keyGen = 1,
  }) async {
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
      // A3: una rotación a medias de otra instalación (Keychain de iOS) no se
      // hereda; la generación es la del respaldo restaurado.
      await _rotation.clearAll();
      _dropNextKeys();
      await _writeKeyGen(keyGen);
      await _safeDeleteBiometricKey();
      await _limiter.reset();
      await _storage.write(pinEnvelopeKey, envelope.encode());
    } catch (_) {
      await _storage.delete(pinEnvelopeKey);
      await _storage.delete(recoveryBackupKey);
      await _storage.delete(keyCheckKey);
      rethrow;
    }
    _session.open(keys, gen: keyGen);
  }

  Future<void> _writeKeyGen(int gen) async {
    if (gen < 1) throw ArgumentError.value(gen, 'gen');
    if (gen == 1) {
      await _storage.delete(keyGenKey); // ausente = 1 (la bóveda original)
    } else {
      await _storage.write(keyGenKey, '$gen');
    }
  }

  /// Generación de la DEK vigente (D60). 1 si nunca se rotó.
  Future<int> currentKeyGen() async {
    final v = int.tryParse(await _storage.read(keyGenKey) ?? '');
    return v == null || v < 1 ? 1 : v;
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

  /// Como [verifyRecoveryCode] pero contra VARIOS respaldos (D61: tras una
  /// rotación puede haber respaldos de varias generaciones y el puente). Se
  /// prueban en el orden dado y cuenta como UN solo intento. Devuelve el
  /// índice del respaldo que abrió y sus llaves, o `null`.
  Future<(int, RecoveryCandidate)?> verifyRecoveryCodeAny({
    required String recoveryCode,
    required List<String> recoveryBackupJsons,
  }) async {
    final backups = [
      for (final j in recoveryBackupJsons) RecoveryBackup.parse(j),
    ];
    if (RecoveryCode.normalize(recoveryCode) == null) return null;
    return _serialized(() async {
      await _restoreLimiter.ensureNotLocked();
      await _restoreLimiter.registerFailure();
      for (var i = 0; i < backups.length; i++) {
        final dek = await _recovery.recoverDek(recoveryCode, backups[i]);
        if (dek == null) continue;
        try {
          final keys = await KeyHierarchy.fromDek(dek);
          await _restoreLimiter.reset();
          return (i, RecoveryCandidate._(keys, recoveryBackupJsons[i]));
        } finally {
          dek.fillRange(0, dek.length, 0);
        }
      }
      return null;
    });
  }

  /// F9, paso final: consolida [candidate] como la bóveda de este
  /// dispositivo con [newPin] (envoltura nueva, la biometría vieja se
  /// descarta) y deja la sesión desbloqueada. Si falla, no queda estado.
  ///
  /// [keyGen] (D60): generación de la DEK del respaldo restaurado (la del
  /// nombre `recovery_backup[.kN].json`).
  Future<void> commitRestore(
    RecoveryCandidate candidate,
    String newPin, {
    int keyGen = 1,
  }) {
    _checkPin(newPin);
    return _serialized(() async {
      if (await hasVault()) {
        throw StateError('Ya existe una bóveda en este dispositivo');
      }
      final dek = candidate.keys.dekBytes();
      try {
        await _commit(
          dek,
          candidate.keys,
          candidate.backupJson,
          newPin,
          keyGen: keyGen,
        );
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
    // D63: desde `reencrypting` hasta el final de la rotación la biometría
    // queda apagada (la envoltura del PIN aún no es la de la DEK nueva).
    final rec = await _rotation.load();
    if (rec != null &&
        rec.effectivePhase.index >= RotationPhase.reencrypting.index) {
      throw const RotationInProgressException(
        'La biometría se reactiva al terminar el cambio de llave maestra',
      );
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
      await _openKeys(keys, gen);
      return true;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  /// Abre la sesión salvo que se haya bloqueado desde que empezó el desbloqueo.
  void _openChecked(VaultKeyring ring, int gen) {
    if (gen != _lockGeneration) {
      ring.destroy();
      throw const UnlockCancelledException();
    }
    _session.openKeyring(ring);
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

  Future<void> _openSession(Uint8List dek, int gen, {String? pin}) async {
    final keys = await KeyHierarchy.fromDek(dek);
    // Autorreparación: versiones sin key_check guardado.
    if (await _storage.read(keyCheckKey) == null) {
      await _storage.write(keyCheckKey, keys.keyCheck);
    }
    await _openKeys(keys, gen, pin: pin);
  }

  /// Abre la sesión con [keys] (la DEK que dio la envoltura del PIN o la
  /// biometría), según la rotación de la DEK registrada (§4.2):
  ///
  /// * Sin rotación: una sola generación (`vault.v1.key_gen`).
  /// * [keys] es la DEK NUEVA (ya se cambió la envoltura del PIN): una sola
  ///   generación, la nueva.
  /// * [keys] es la DEK VIEJA:
  ///   - hasta `freezing`: la sesión sigue con la vieja; con [pin] se obtiene
  ///     además la nueva de `next_pin_envelope` (2.º Argon2id, NO cuenta
  ///     intento) y se guarda solo en memoria para continuar;
  ///   - de `reencrypting` en adelante: sesión con las DOS (nueva = actual).
  /// * [keys] no es ninguna de las dos: el registro no es de esta bóveda
  ///   (`blockedForeign`, L8) y la sesión abre igualmente.
  Future<void> _openKeys(KeyHierarchy keys, int gen, {String? pin}) async {
    await _rotation.sweepOrphans();
    final rec = await _rotation.load();
    if (rec == null) {
      _openChecked(VaultKeyring.single(await currentKeyGen(), keys), gen);
      return;
    }
    if (keys.keyCheck == rec.newKeyCheck) {
      _dropNextKeys();
      _openChecked(VaultKeyring.single(rec.toGen, keys), gen);
      return;
    }
    if (keys.keyCheck != rec.oldKeyCheck) {
      if (rec.phase != RotationPhase.blockedForeign) {
        await _rotation.save(
          rec.copyWith(
            phase: RotationPhase.blockedForeign,
            resumePhase: rec.effectivePhase,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      _openChecked(VaultKeyring.single(await currentKeyGen(), keys), gen);
      return;
    }
    KeyHierarchy? next = hasNextKeys ? _nextKeys : null;
    if (next == null && pin != null) {
      next = await _unwrapNextWithPin(pin, rec);
    }
    // Con la DEK vieja, de `reencrypting` en adelante (también si una fase
    // posterior quedó escrita pero la envoltura del PIN no llegó a cambiar:
    // se repetirá `switchingLocal`) hacen falta las dos.
    if (rec.effectivePhase.index <= RotationPhase.freezing.index) {
      // Hasta congelar, todo lo nuevo se sigue cifrando con la vieja.
      if (next != null && !identical(next, _nextKeys)) {
        _dropNextKeys();
        _nextKeys = next;
      }
      _openChecked(VaultKeyring.single(rec.fromGen, keys), gen);
      return;
    }
    if (next == null) {
      // Falta la DEK nueva (envoltura perdida o dañada): la sesión abre con
      // la vieja y la rotación espera al código nuevo B (§9).
      if (pin != null && rec.phase != RotationPhase.blockedCorrupt) {
        await _rotation.save(
          rec.copyWith(
            phase: RotationPhase.blockedCorrupt,
            resumePhase: rec.effectivePhase,
            lastError: 'Falta la llave nueva',
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      _openChecked(VaultKeyring.single(rec.fromGen, keys), gen);
      return;
    }
    if (identical(next, _nextKeys)) _nextKeys = null; // pasa a la sesión
    _openChecked(
      VaultKeyring.dual(
        currentGen: rec.toGen,
        current: next,
        previousGen: rec.fromGen,
        previous: keys,
      ),
      gen,
    );
  }

  /// DEK nueva de `next_pin_envelope` con [pin] (ya verificado: no cuenta
  /// intento), comprobada contra el `newKeyCheck` del registro. `null` si
  /// falta, no abre o no corresponde.
  Future<KeyHierarchy?> _unwrapNextWithPin(
    String pin,
    RotationRecord rec,
  ) async {
    final raw = await _rotation.read(RotationKeyStore.nextPinEnvelopeKey);
    if (raw == null) return null;
    final Uint8List? dek;
    try {
      dek = await WrappedKey.decode(
        raw,
        expectedPurpose: WrapPurpose.pin,
      ).unwrap(utf8.encode(pin));
    } on FormatException {
      return null;
    }
    if (dek == null) return null;
    try {
      final keys = await KeyHierarchy.fromDek(dek);
      if (keys.keyCheck != rec.newKeyCheck) {
        keys.destroy();
        return null;
      }
      return keys;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  void _dropNextKeys() {
    _nextKeys?.destroy();
    _nextKeys = null;
  }

  /// Bloquea: destruye las llaves en memoria y CANCELA cualquier desbloqueo en
  /// curso (derivación Argon2/biometría): al terminar no abrirá la sesión.
  void lock() {
    _lockGeneration++;
    _dropNextKeys();
    _session.clear();
  }

  // ---------------------------------------------------------------------
  // Rotación de la DEK (S-11, docs/DISENO_ROTACION.md §4)
  // ---------------------------------------------------------------------
  //
  // Material de llaves de una rotación, y qué lo abre:
  // * next_pin_envelope      = DEK_new con el PIN        (local)
  // * next_recovery_backup   = DEK_new con el código B   (local; Drive tras el corte)
  // * bridge_backup (puente) = DEK_old con el código B   (local hasta subirlo)
  // NADA envuelve la DEK nueva con el código viejo A ni con la DEK vieja.

  /// Registro de la rotación (o `null`).
  Future<RotationRecord?> rotationRecord() => _rotation.load();

  Future<void> _requireNoRotation() async {
    if (await _rotation.load() != null) {
      throw const RotationInProgressException();
    }
  }

  /// Empieza una rotación (fase `prepared`): verifica [pin] (cuenta intento),
  /// crea la DEK nueva, el código nuevo B y sus envolturas LOCALES (PIN y B)
  /// y, al final, el registro. Devuelve B formateado para mostrarlo una vez,
  /// o `null` si el PIN es incorrecto.
  ///
  /// [toGen]: generación nueva (mayor que la vigente y que cualquiera vista
  /// en Drive; la calcula el llamador). [accountEmail]: cuenta de Google con
  /// la que se rota. El llamador comprueba además que no haya un cambio de
  /// cuenta en curso. Exige la sesión abierta con la DEK vigente.
  Future<String?> prepareRotation(
    String pin, {
    required int toGen,
    required String accountEmail,
    RotationReason reason = RotationReason.rotateKey,
  }) => _serialized(() async {
    await _requireNoRotation();
    final fromGen = await currentKeyGen();
    if (toGen <= fromGen) {
      throw ArgumentError.value(toGen, 'toGen', 'Debe ser mayor que $fromGen');
    }
    final current = _session.keysOrNull;
    if (current == null || _session.keyring!.isDual) {
      throw StateError('La bóveda está bloqueada');
    }
    final dekOld = await _verifyPin(pin, ++_attemptSeq);
    if (dekOld == null) return null;
    final dekNew = randomBytes(32, _random);
    try {
      final oldKeys = await KeyHierarchy.fromDek(dekOld);
      final oldCheck = oldKeys.keyCheck;
      oldKeys.destroy();
      if (oldCheck != current.keyCheck) {
        throw StateError('La sesión no corresponde a la envoltura del PIN');
      }
      final code = _recovery.generateRecoveryCode();
      final nextBackup = await _recovery.createBackup(dekNew, code);
      final nextPin = await _wrapWithPin(dekNew, pin);
      final newKeys = await KeyHierarchy.fromDek(dekNew);
      // Orden: secretos auxiliares primero, el registro AL FINAL.
      await _rotation.write(
        RotationKeyStore.nextRecoveryBackupKey,
        nextBackup.toJsonString(),
      );
      await _rotation.write(
        RotationKeyStore.nextPinEnvelopeKey,
        nextPin.encode(),
      );
      await _rotation.delete(RotationKeyStore.bridgeBackupKey);
      final now = DateTime.now().millisecondsSinceEpoch;
      await _rotation.save(
        RotationRecord(
          id: _newRotationId(),
          fromGen: fromGen,
          toGen: toGen,
          phase: RotationPhase.prepared,
          reason: reason,
          oldKeyCheck: oldCheck,
          newKeyCheck: newKeys.keyCheck,
          accountEmail: accountEmail,
          startedAt: now,
          updatedAt: now,
        ),
      );
      _dropNextKeys();
      _nextKeys = newKeys;
      return RecoveryCode.format(code);
    } finally {
      dekOld.fillRange(0, dekOld.length, 0);
      dekNew.fillRange(0, dekNew.length, 0);
    }
  });

  String _newRotationId() {
    final b = randomBytes(16, _random);
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// M1: genera OTRO código nuevo para la MISMA DEK nueva (p. ej. la app se
  /// cerró con el código en pantalla sin confirmar). Solo en `prepared`.
  /// Verifica [pin] (cuenta intento). Devuelve el código o `null` si el PIN
  /// es incorrecto.
  Future<String?> regenerateNextRecoveryCode(String pin) =>
      _serialized(() async {
        final rec = await _rotation.load();
        if (rec == null || rec.phase != RotationPhase.prepared) {
          throw const RotationInProgressException(
            'Solo se puede generar otro código antes de confirmarlo',
          );
        }
        final dekOld = await _verifyPin(pin, ++_attemptSeq);
        if (dekOld == null) return null;
        dekOld.fillRange(0, dekOld.length, 0);
        final next = await _unwrapNextWithPin(pin, rec);
        if (next == null) {
          throw const RotationInProgressException('Falta la llave nueva');
        }
        final dekNew = next.dekBytes();
        try {
          final code = _recovery.generateRecoveryCode();
          final backup = await _recovery.createBackup(dekNew, code);
          await _rotation.write(
            RotationKeyStore.nextRecoveryBackupKey,
            backup.toJsonString(),
          );
          // Un puente con el código anterior ya no vale.
          await _rotation.delete(RotationKeyStore.bridgeBackupKey);
          _dropNextKeys();
          _nextKeys = next;
          return RecoveryCode.format(code);
        } finally {
          dekNew.fillRange(0, dekNew.length, 0);
        }
      });

  /// El usuario confirmó el código nuevo B (`prepared` → `confirmed`).
  ///
  /// [code] se comprueba contra `next_recovery_backup` (Argon2id): debe abrir
  /// la DEK nueva. Con él se crea el RESPALDO PUENTE: la DEK VIEJA envuelta
  /// con B (salt propio), que se sube en `freezing` para que B restaure el
  /// conjunto viejo hasta el corte (A2). Devuelve `false` si [code] no es el
  /// de esta rotación. Exige la sesión abierta con la DEK vieja.
  Future<bool> confirmRotationCode(String code) => _serialized(() async {
    final rec = await _rotation.load();
    if (rec == null) throw const RotationInProgressException('No hay rotación');
    if (rec.phase == RotationPhase.confirmed &&
        await _rotation.read(RotationKeyStore.bridgeBackupKey) != null) {
      return true; // ya confirmado
    }
    if (rec.phase != RotationPhase.prepared) {
      throw const RotationInProgressException(
        'El código ya no se puede confirmar en esta fase',
      );
    }
    final old = _session.keyring?.forGenOrNull(rec.fromGen);
    if (old == null || old.isDestroyed || old.keyCheck != rec.oldKeyCheck) {
      throw StateError('La bóveda está bloqueada');
    }
    final raw = await _rotation.read(RotationKeyStore.nextRecoveryBackupKey);
    if (raw == null) {
      throw const RotationInProgressException('Falta el respaldo nuevo');
    }
    final dekNew = await _recovery.recoverDek(code, RecoveryBackup.parse(raw));
    if (dekNew == null) return false;
    final dekOld = old.dekBytes();
    try {
      final newKeys = await KeyHierarchy.fromDek(dekNew);
      if (newKeys.keyCheck != rec.newKeyCheck) {
        newKeys.destroy();
        return false;
      }
      final bridge = await _recovery.createBackup(dekOld, code);
      await _rotation.write(
        RotationKeyStore.bridgeBackupKey,
        bridge.toJsonString(),
      );
      await _rotation.save(
        rec.copyWith(
          phase: RotationPhase.confirmed,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (hasNextKeys) {
        newKeys.destroy();
      } else {
        _nextKeys = newKeys;
      }
      return true;
    } finally {
      dekNew.fillRange(0, dekNew.length, 0);
      dekOld.fillRange(0, dekOld.length, 0);
    }
  });

  /// Respaldo puente pendiente de subir (JSON), o `null`.
  Future<String?> pendingBridgeBackup() =>
      _rotation.read(RotationKeyStore.bridgeBackupKey);

  /// El puente ya está en Drive (verificado): se borra la copia local.
  Future<void> bridgeBackupUploaded() =>
      _rotation.delete(RotationKeyStore.bridgeBackupKey);

  /// Cancela una rotación que aún no re-cifró nada (hasta `freezing`):
  /// borra los secretos locales y el registro. Lo de Drive (el puente) y la
  /// BD (triggers y filas de la rotación) los deshace el servicio de
  /// rotación ANTES de llamar a esto.
  Future<void> abandonRotation() => _serialized(() async {
    final rec = await _rotation.load();
    if (rec == null) return;
    if (!rec.isCancellable) {
      throw const RotationInProgressException(
        'El cambio de llave ya empezó: solo se puede pausar',
      );
    }
    _dropNextKeys();
    await _rotation.clearAll();
  });

  /// Paso a `reencrypting` (desde `freezing`, con el conjunto viejo ya
  /// congelado): la biometría se desactiva (su archivo guarda la DEK vieja;
  /// se ofrece reactivarla al terminar) y la sesión pasa a tener las dos
  /// llaves (lo nuevo se cifra con la nueva). Exige la DEK nueva en memoria
  /// ([hasNextKeys]); si no, lanza [RotationInProgressException] y hay que
  /// desbloquear con el PIN.
  Future<void> enterReencrypting() => _serialized(() async {
    var rec = await _rotation.load();
    if (rec == null) throw const RotationInProgressException('No hay rotación');
    final ring = _session.keyring;
    if (rec.effectivePhase == RotationPhase.reencrypting &&
        ring != null &&
        ring.isDual) {
      return; // ya hecho
    }
    if (rec.phase != RotationPhase.freezing &&
        rec.phase != RotationPhase.reencrypting) {
      throw const RotationInProgressException('Fase incorrecta');
    }
    final old = ring?.forGenOrNull(rec.fromGen);
    if (old == null || old.isDestroyed || old.keyCheck != rec.oldKeyCheck) {
      throw StateError('La bóveda está bloqueada');
    }
    final next = _nextKeys;
    if (next == null || next.isDestroyed) {
      throw const RotationInProgressException(
        'Desbloquea con tu PIN para continuar el cambio de llave',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (await isBiometricUnlockEnabled()) {
      rec = rec.copyWith(biometricWasEnabled: true, updatedAt: now);
      await _rotation.save(rec);
      await disableBiometricUnlock();
    }
    await _rotation.save(
      rec.copyWith(phase: RotationPhase.reencrypting, updatedAt: now),
    );
    _nextKeys = null;
    _session.openKeyring(
      VaultKeyring.dual(
        currentGen: rec.toGen,
        current: next,
        previousGen: rec.fromGen,
        previous: old,
      ),
    );
  });

  /// `switchingLocal` (tras re-cifrar la BD, D63): el respaldo local, el
  /// `key_check`, la generación y, AL FINAL, la envoltura del PIN pasan a la
  /// DEK nueva; se borran las envolturas `next_*` y la sesión queda solo con
  /// la nueva (la vieja se destruye). Idempotente.
  Future<void> switchPrimary() => _serialized(() async {
    final rec = await _rotation.load();
    if (rec == null) throw const RotationInProgressException('No hay rotación');
    if (rec.effectivePhase != RotationPhase.switchingLocal) {
      throw const RotationInProgressException('Fase incorrecta');
    }
    final current = _session.keysOrNull;
    if (current == null ||
        current.isDestroyed ||
        current.keyCheck != rec.newKeyCheck) {
      throw StateError('La sesión no tiene la llave nueva');
    }
    final nextBackup = await _rotation.read(
      RotationKeyStore.nextRecoveryBackupKey,
    );
    if (nextBackup != null) {
      await _storage.write(recoveryBackupKey, nextBackup);
    }
    await _storage.write(keyCheckKey, rec.newKeyCheck);
    await _writeKeyGen(rec.toGen);
    final nextPin = await _rotation.read(RotationKeyStore.nextPinEnvelopeKey);
    if (nextPin != null) {
      // La ÚLTIMA escritura que importa: desde aquí el PIN da la DEK nueva.
      await _storage.write(pinEnvelopeKey, nextPin);
    }
    await _rotation.delete(RotationKeyStore.nextPinEnvelopeKey);
    await _rotation.delete(RotationKeyStore.nextRecoveryBackupKey);
    _session.openKeyring(VaultKeyring.single(rec.toGen, current));
  });

  /// "Comprobar mi código" (M1): `true` si [code] abre el respaldo de
  /// recuperación LOCAL vigente (sin red; cuenta en el límite de intentos
  /// del código). Lanza [PinLockedOutException] si hay que esperar.
  Future<bool> verifyLocalRecoveryCode(String code) async {
    if (RecoveryCode.normalize(code) == null) return false;
    return _serialized(() async {
      final raw = await _storage.read(recoveryBackupKey);
      if (raw == null) return false;
      await _restoreLimiter.ensureNotLocked();
      await _restoreLimiter.registerFailure();
      final dek = await _recovery.recoverDek(code, RecoveryBackup.parse(raw));
      if (dek == null) return false;
      dek.fillRange(0, dek.length, 0);
      await _restoreLimiter.reset();
      return true;
    });
  }
}
