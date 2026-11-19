import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'key_hierarchy.dart';
import 'secure_kv_store.dart';

/// Fases de una rotación de la DEK (`docs/DISENO_ROTACION.md` §3).
enum RotationPhase {
  /// DEK nueva y código B creados; B en pantalla, SIN confirmar.
  prepared,

  /// B confirmado (y el respaldo puente generado); esperando precondiciones.
  confirmed,

  /// Congelando el conjunto viejo en Drive (snapshot propio + puente).
  freezing,

  /// Re-cifrando items: la sesión tiene las dos llaves.
  reencrypting,
  uploading,
  rekeyingDb,

  /// La envoltura del PIN pasa a la DEK nueva.
  switchingLocal,
  uploadingSnapshot,

  /// Al verificar `recovery_backup.kN.json`: CORTE.
  uploadingBackup,
  deletingOldCloud,
  finalizingLocal,

  blockedQuota,
  blockedLocalSpace,
  blockedSignIn,
  blockedCorrupt,

  /// El registro no corresponde a esta bóveda (A3/L8).
  blockedForeign;

  bool get isBlocked => index >= RotationPhase.blockedQuota.index;

  static RotationPhase? byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// Por qué se lanzó la rotación (solo cambia los textos de la UI).
enum RotationReason { newCode, rotateKey }

/// Registro de una rotación en curso (`vault.v1.rotation`). No contiene
/// ningún secreto: solo fases, generaciones y `keyCheck` (HKDF de cada DEK).
@immutable
class RotationRecord {
  const RotationRecord({
    required this.id,
    required this.fromGen,
    required this.toGen,
    required this.phase,
    required this.reason,
    required this.oldKeyCheck,
    required this.newKeyCheck,
    required this.accountEmail,
    required this.startedAt,
    required this.updatedAt,
    this.biometricWasEnabled = false,
    this.lastError,
    this.resumePhase,
  });

  static const int formatVersion = 1;

  final String id;
  final int fromGen;
  final int toGen;
  final RotationPhase phase;
  final RotationReason reason;
  final String oldKeyCheck;
  final String newKeyCheck;

  /// Cuenta de Google con la que empezó (solo para comparar; nunca a logs).
  final String accountEmail;
  final bool biometricWasEnabled;
  final int startedAt;
  final int updatedAt;
  final String? lastError;

  /// Fase a la que se vuelve al salir de un bloqueo (`blocked*`).
  final RotationPhase? resumePhase;

  /// La fase "real": la de [resumePhase] si está bloqueada.
  RotationPhase get effectivePhase =>
      phase.isBlocked ? (resumePhase ?? RotationPhase.prepared) : phase;

  /// Se puede cancelar sin re-cifrar nada (hasta `freezing`, D61).
  bool get isCancellable =>
      effectivePhase.index <= RotationPhase.freezing.index;

  /// Entre la congelación y el corte: el conjunto viejo de Drive está
  /// congelado (D61).
  bool get freezeMeta {
    final p = effectivePhase;
    return p.index >= RotationPhase.freezing.index &&
        p.index <= RotationPhase.uploadingBackup.index;
  }

  /// La sesión necesita las dos llaves (D63): de `reencrypting` hasta que la
  /// envoltura del PIN pasa a la nueva (`switchingLocal`).
  bool get needsBothKeys {
    final p = effectivePhase;
    return p.index >= RotationPhase.reencrypting.index &&
        p.index <= RotationPhase.switchingLocal.index;
  }

  RotationRecord copyWith({
    RotationPhase? phase,
    bool? biometricWasEnabled,
    int? updatedAt,
    Object? lastError = _keep,
    Object? resumePhase = _keep,
  }) => RotationRecord(
    id: id,
    fromGen: fromGen,
    toGen: toGen,
    phase: phase ?? this.phase,
    reason: reason,
    oldKeyCheck: oldKeyCheck,
    newKeyCheck: newKeyCheck,
    accountEmail: accountEmail,
    startedAt: startedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    biometricWasEnabled: biometricWasEnabled ?? this.biometricWasEnabled,
    lastError: identical(lastError, _keep)
        ? this.lastError
        : lastError as String?,
    resumePhase: identical(resumePhase, _keep)
        ? this.resumePhase
        : resumePhase as RotationPhase?,
  );

  static const Object _keep = Object();

  Map<String, dynamic> toJson() => {
    'v': formatVersion,
    'id': id,
    'fromGen': fromGen,
    'toGen': toGen,
    'phase': phase.name,
    'reason': reason.name,
    'oldKeyCheck': oldKeyCheck,
    'newKeyCheck': newKeyCheck,
    'accountEmail': accountEmail,
    'biometricWasEnabled': biometricWasEnabled,
    'startedAt': startedAt,
    'updatedAt': updatedAt,
    'lastError': lastError,
    'resumePhase': resumePhase?.name,
  };

  String encode() => jsonEncode(toJson());

  /// Lanza [FormatException] si [source] no es un registro válido.
  static RotationRecord decode(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Registro de rotación ilegible');
    }
    if (json is! Map<String, dynamic> || json['v'] != formatVersion) {
      throw const FormatException('Registro de rotación no soportado');
    }
    final map = json;
    T field<T>(String k) {
      final v = map[k];
      if (v is! T) throw FormatException('Registro de rotación: falta $k');
      return v;
    }

    final phase = RotationPhase.byName(field<String>('phase'));
    if (phase == null) throw const FormatException('Fase desconocida');
    final reason = RotationReason.values.firstWhere(
      (r) => r.name == map['reason'],
      orElse: () => RotationReason.rotateKey,
    );
    final fromGen = field<int>('fromGen');
    final toGen = field<int>('toGen');
    if (fromGen < 1 || toGen <= fromGen) {
      throw const FormatException('Generaciones inválidas');
    }
    return RotationRecord(
      id: field<String>('id'),
      fromGen: fromGen,
      toGen: toGen,
      phase: phase,
      reason: reason,
      oldKeyCheck: field<String>('oldKeyCheck'),
      newKeyCheck: field<String>('newKeyCheck'),
      accountEmail: field<String>('accountEmail'),
      startedAt: field<int>('startedAt'),
      updatedAt: field<int>('updatedAt'),
      biometricWasEnabled: json['biometricWasEnabled'] == true,
      lastError: json['lastError'] as String?,
      resumePhase: RotationPhase.byName(json['resumePhase'] as String?),
    );
  }
}

/// Persistencia de la rotación en el almacén seguro LOCAL (§2.1).
///
/// El registro va en `vault.v1.rotation` y es lo ÚLTIMO que se escribe al
/// empezar y lo ÚLTIMO que se borra al terminar: secretos auxiliares sin
/// registro son huérfanos y [sweepOrphans] los borra.
///
/// Secretos auxiliares (nunca salen del teléfono; ninguno deriva del código
/// viejo A):
/// * [nextPinEnvelopeKey]: DEK nueva envuelta con el PIN.
/// * [nextRecoveryBackupKey]: DEK nueva envuelta con el código nuevo B.
/// * [bridgeBackupKey]: DEK VIEJA envuelta con B (respaldo puente, hasta
///   subirlo a Drive).
class RotationKeyStore {
  RotationKeyStore(this._storage);

  /// Instancia de la app (sobre el almacén seguro real). Comparte [record]
  /// entre el `AuthController`, la sincronización y el servicio de rotación.
  static final RotationKeyStore shared = RotationKeyStore(
    FlutterSecureKeyValueStore(),
  );

  static const String recordKey = 'vault.v1.rotation';
  static const String nextPinEnvelopeKey =
      'vault.v1.rotation.next_pin_envelope';
  static const String nextRecoveryBackupKey =
      'vault.v1.rotation.next_recovery_backup';
  static const String bridgeBackupKey = 'vault.v1.rotation.bridge_backup';

  /// Todas las claves de la rotación (A3: se borran al descartar las llaves
  /// locales y al restaurar).
  static const List<String> allKeys = [
    recordKey,
    nextPinEnvelopeKey,
    nextRecoveryBackupKey,
    bridgeBackupKey,
  ];

  static const List<String> _auxKeys = [
    nextPinEnvelopeKey,
    nextRecoveryBackupKey,
    bridgeBackupKey,
  ];

  final SecureKeyValueStore _storage;

  /// DEK NUEVA de la rotación solo en MEMORIA (`prepared`..`freezing`, ver
  /// la nota de implementación del paso 6). Vive aquí y no en un
  /// `AuthController` concreto para que la compartan el que desbloquea (la
  /// pantalla del PIN) y el que usa el servicio de rotación. Nunca se
  /// escribe en disco; `AuthController.lock` la destruye.
  KeyHierarchy? nextKeys;

  /// Último registro leído o escrito (`null` = sin rotación). La
  /// sincronización lo lee de forma síncrona (RotationGuard).
  final ValueNotifier<RotationRecord?> record = ValueNotifier(null);

  /// Lee el registro. Uno ilegible se trata como ausente (no se borra: la
  /// sesión lo ignora y el servicio lo reporta).
  Future<RotationRecord?> load() async {
    final raw = await _storage.read(recordKey);
    RotationRecord? rec;
    if (raw != null) {
      try {
        rec = RotationRecord.decode(raw);
      } on FormatException {
        rec = null;
      }
    }
    record.value = rec;
    return rec;
  }

  Future<void> save(RotationRecord rec) async {
    await _storage.write(recordKey, rec.encode());
    record.value = rec;
  }

  Future<String?> read(String key) => _storage.read(key);
  Future<void> write(String key, String value) => _storage.write(key, value);
  Future<void> delete(String key) => _storage.delete(key);

  /// Borra los secretos auxiliares si no hay registro (restos de un
  /// `prepareRotation` interrumpido antes de escribir el registro).
  Future<void> sweepOrphans() async {
    if (await _storage.read(recordKey) != null) return;
    for (final k in _auxKeys) {
      await _storage.delete(k);
    }
  }

  /// Borra todas las claves de la rotación: auxiliares primero, el registro
  /// al final.
  Future<void> clearAll() async {
    for (final k in _auxKeys) {
      await _storage.delete(k);
    }
    await _storage.delete(recordKey);
    record.value = null;
  }
}
