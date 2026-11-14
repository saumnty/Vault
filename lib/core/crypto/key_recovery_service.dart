import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'kdf.dart';
import 'wrapped_key.dart';

/// Código de recuperación: 24 caracteres aleatorios de un alfabeto de 31
/// símbolos sin ambiguos (sin 0/O, 1/I/L). Entropía ≈ 24·log2(31) ≈ 119 bits.
///
/// Se muestra en grupos de 4 ("ABCD-EFGH-...") pero al derivar se normaliza:
/// mayúsculas, sin guiones ni espacios.
class RecoveryCode {
  RecoveryCode._();

  static const String alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  static const int length = 24;
  static const int groupSize = 4;

  /// Genera un código nuevo ya normalizado (sin separadores).
  /// `Random.nextInt` de `Random.secure()` es uniforme (sin sesgo de módulo).
  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// "ABCDEFGH..." → "ABCD-EFGH-...". Para mostrar al usuario.
  static String format(String code) {
    final normalized = normalize(code) ?? code;
    final groups = <String>[];
    for (var i = 0; i < normalized.length; i += groupSize) {
      groups.add(
        normalized.substring(i, min(i + groupSize, normalized.length)),
      );
    }
    return groups.join('-');
  }

  /// Normaliza lo que escribe el usuario. Devuelve `null` si, tras quitar
  /// separadores, no es un código con formato válido.
  static String? normalize(String input) {
    final cleaned = input.toUpperCase().replaceAll(RegExp(r'[\s\-_.]'), '');
    if (cleaned.length != length) return null;
    for (final ch in cleaned.split('')) {
      if (!alphabet.contains(ch)) return null;
    }
    return cleaned;
  }
}

/// Respaldo de recuperación: una copia de la DEK envuelta con
/// KEK_rec = Argon2id(código de recuperación, salt2).
///
/// Es el ÚNICO material de llaves que puede salir del teléfono (F5 lo sube a
/// Drive appDataFolder). No contiene la DEK, ni el código, ni nada derivado
/// del PIN.
class RecoveryBackup {
  RecoveryBackup._(this.wrapped);

  static const String type = 'vault.recovery-backup';

  final WrappedKey wrapped;

  String toJsonString() => jsonEncode({'type': type, ...wrapped.toJson()});

  /// Lanza [FormatException] si [source] no es un respaldo válido.
  static RecoveryBackup parse(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      throw const FormatException('El respaldo no es JSON válido');
    }
    if (json is! Map<String, dynamic> || json['type'] != type) {
      throw const FormatException('No es un respaldo de recuperación de Vault');
    }
    return RecoveryBackup._(
      WrappedKey.fromJson(json, expectedPurpose: WrapPurpose.recovery),
    );
  }
}

/// Crea y abre respaldos de recuperación.
class KeyRecoveryService {
  KeyRecoveryService({this.kdfParams = Argon2Params.production, Random? random})
    : _random = random ?? Random.secure();

  final Argon2Params kdfParams;
  final Random _random;

  String generateRecoveryCode() => RecoveryCode.generate(_random);

  /// Envuelve [dek] con el [recoveryCode] (se normaliza antes de derivar).
  Future<RecoveryBackup> createBackup(
    List<int> dek,
    String recoveryCode,
  ) async {
    final normalized = RecoveryCode.normalize(recoveryCode);
    if (normalized == null) {
      throw ArgumentError('Código de recuperación con formato inválido');
    }
    final wrapped = await WrappedKey.wrap(
      dek: dek,
      secret: utf8.encode(normalized),
      purpose: WrapPurpose.recovery,
      kdf: kdfParams,
      random: _random,
    );
    return RecoveryBackup._(wrapped);
  }

  /// Devuelve la DEK, o `null` si el código es incorrecto / mal formado.
  Future<Uint8List?> recoverDek(
    String recoveryCode,
    RecoveryBackup backup,
  ) async {
    final normalized = RecoveryCode.normalize(recoveryCode);
    if (normalized == null) return null;
    return backup.wrapped.unwrap(utf8.encode(normalized));
  }
}
