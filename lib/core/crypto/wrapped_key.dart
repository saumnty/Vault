import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'aes_gcm_backend.dart';
import 'kdf.dart';

/// Propósito de una envoltura de la DEK. Se autentica como AAD, de modo que
/// una envoltura de PIN no puede hacerse pasar por una de recuperación.
enum WrapPurpose { pin, recovery }

/// La DEK envuelta (cifrada) con una KEK derivada por Argon2id.
///
///   KEK = Argon2id(secreto, salt, params)
///   envoltura = AES-256-GCM(KEK, nonce, DEK, aad = "vault.dek.v1|{propósito}")
///
/// Es serializable a JSON (todo en base64). No contiene la DEK ni la KEK en
/// claro: solo el texto cifrado, el nonce, el MAC, el salt y los parámetros.
class WrappedKey {
  WrappedKey._({
    required this.purpose,
    required this.kdf,
    required this.salt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  static const int formatVersion = 1;
  static const int saltLength = 16;
  static const int nonceLength = 12;
  static const int macLength = 16;
  static const int keyLength = 32;

  // Se resuelve en cada uso (D22). Con 32 bytes siempre va por Dart: queda
  // por debajo de FallbackAesGcmBackend.minNativeLength.
  static AesGcmBackend get _aes => AesGcmBackend.current;

  final WrapPurpose purpose;
  final Argon2Params kdf;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  static List<int> _aad(WrapPurpose purpose) =>
      utf8.encode('vault.dek.v$formatVersion|${purpose.name}');

  /// Envuelve [dek] con una KEK derivada de [secret] usando un salt nuevo.
  static Future<WrappedKey> wrap({
    required List<int> dek,
    required List<int> secret,
    required WrapPurpose purpose,
    required Argon2Params kdf,
    Random? random,
  }) async {
    if (dek.length != keyLength) {
      throw ArgumentError('La DEK debe medir $keyLength bytes');
    }
    final rng = random ?? Random.secure();
    final salt = randomBytes(saltLength, rng);
    final nonce = randomBytes(nonceLength, rng);
    final kek = await kdf.deriveKey(secret, salt);
    try {
      final box = await _aes.encrypt(
        dek,
        secretKey: kek,
        nonce: nonce,
        aad: _aad(purpose),
      );
      return WrappedKey._(
        purpose: purpose,
        kdf: kdf,
        salt: salt,
        nonce: nonce,
        cipherText: Uint8List.fromList(box.cipherText),
        mac: Uint8List.fromList(box.mac.bytes),
      );
    } finally {
      kek.destroy();
    }
  }

  /// Intenta recuperar la DEK con [secret]. Devuelve `null` si el secreto es
  /// incorrecto (o la envoltura fue manipulada): AES-GCM no autentica.
  Future<Uint8List?> unwrap(List<int> secret) async {
    final kek = await kdf.deriveKey(secret, salt);
    try {
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: kek,
        aad: _aad(purpose),
      );
      if (clear.length != keyLength) return null;
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      return null;
    } finally {
      kek.destroy();
    }
  }

  Map<String, dynamic> toJson() => {
    'v': formatVersion,
    'purpose': purpose.name,
    'kdf': kdf.toJson(),
    'salt': base64Encode(salt),
    'nonce': base64Encode(nonce),
    'ct': base64Encode(cipherText),
    'mac': base64Encode(mac),
  };

  /// Lanza [FormatException] si el JSON no es una envoltura válida.
  factory WrappedKey.fromJson(
    Map<String, dynamic> json, {
    required WrapPurpose expectedPurpose,
  }) {
    if (json['v'] != formatVersion) {
      throw const FormatException('Versión de envoltura no soportada');
    }
    if (json['purpose'] != expectedPurpose.name) {
      throw const FormatException('Propósito de envoltura inesperado');
    }
    final kdfJson = json['kdf'];
    if (kdfJson is! Map<String, dynamic>) {
      throw const FormatException('Falta la KDF');
    }
    Uint8List field(String name, int length) {
      final value = json[name];
      if (value is! String) throw FormatException('Falta el campo $name');
      final Uint8List bytes;
      try {
        bytes = base64Decode(value);
      } on FormatException {
        throw FormatException('Campo $name no es base64');
      }
      if (bytes.length != length) {
        throw FormatException('Longitud inválida en $name');
      }
      return bytes;
    }

    return WrappedKey._(
      purpose: expectedPurpose,
      kdf: Argon2Params.fromJson(kdfJson),
      salt: field('salt', saltLength),
      nonce: field('nonce', nonceLength),
      cipherText: field('ct', keyLength),
      mac: field('mac', macLength),
    );
  }

  String encode() => jsonEncode(toJson());

  static WrappedKey decode(
    String source, {
    required WrapPurpose expectedPurpose,
  }) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      throw const FormatException('JSON inválido');
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Se esperaba un objeto JSON');
    }
    return WrappedKey.fromJson(json, expectedPurpose: expectedPurpose);
  }
}

/// Bytes aleatorios criptográficamente seguros.
Uint8List randomBytes(int length, [Random? random]) {
  final rng = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}
