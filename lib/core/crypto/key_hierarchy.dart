import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Jerarquía de llaves en memoria de una bóveda desbloqueada.
///
///   DEK (256 bits aleatorios, generada una sola vez al crear la bóveda)
///    ├─ HKDF-SHA256(DEK, info="sqlcipher") → contraseña de la BD (F3)
///    ├─ HKDF-SHA256(DEK, info="files")     → cifrado de archivos .vault
///    └─ HKDF-SHA256(DEK, info="thumbs")    → cifrado de miniaturas
///
/// La DEK nunca se usa directamente para cifrar datos; solo se envuelve
/// (PIN / recuperación / biometría) y se deriva.
class KeyHierarchy {
  KeyHierarchy._(
    this._dek,
    this.sqlcipher,
    this.files,
    this.thumbs,
    this.keyCheck,
  );

  static const String infoSqlcipher = 'sqlcipher';
  static const String infoFiles = 'files';
  static const String infoThumbs = 'thumbs';

  /// Etiqueta para el valor de verificación de la DEK (no es una llave de
  /// cifrado; ver [keyCheck]).
  static const String infoKeyCheck = 'key-check';

  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final SecretKeyData _dek;
  final SecretKeyData sqlcipher;
  final SecretKeyData files;
  final SecretKeyData thumbs;

  /// HKDF(DEK, "key-check") truncado a 16 bytes, en base64. Permite comprobar
  /// sin PIN que la DEK leída de la biometría es la de esta bóveda. Al ser
  /// una salida de HKDF no revela nada de la DEK.
  final String keyCheck;

  bool _destroyed = false;
  bool get isDestroyed => _destroyed;

  /// Copia de los bytes de la DEK. Solo para envolverla (cambio de PIN,
  /// biometría, respaldo). No usar para cifrar datos.
  Uint8List dekBytes() {
    _checkAlive();
    return Uint8List.fromList(_dek.bytes);
  }

  /// Construye la jerarquía a partir de los bytes de la DEK (se copian).
  static Future<KeyHierarchy> fromDek(List<int> dekBytes) async {
    if (dekBytes.length != 32) {
      throw ArgumentError('La DEK debe medir 32 bytes');
    }
    final dek = SecretKeyData(
      Uint8List.fromList(dekBytes),
      overwriteWhenDestroyed: true,
    );
    final check = await _derive(dek, infoKeyCheck);
    final keyCheck = base64Encode(check.bytes.sublist(0, 16));
    check.destroy();
    return KeyHierarchy._(
      dek,
      await _derive(dek, infoSqlcipher),
      await _derive(dek, infoFiles),
      await _derive(dek, infoThumbs),
      keyCheck,
    );
  }

  static Future<SecretKeyData> _derive(SecretKeyData dek, String info) async {
    final derived = await _hkdf.deriveKey(
      secretKey: dek,
      // Sin salt: la DEK ya es uniformemente aleatoria (RFC 5869 §3.1).
      nonce: const <int>[],
      info: utf8.encode(info),
    );
    return SecretKeyData(
      Uint8List.fromList(derived.bytes),
      overwriteWhenDestroyed: true,
    );
  }

  /// Sobrescribe con ceros los bytes de todas las llaves (mejor esfuerzo:
  /// el GC de Dart puede haber dejado copias que no controlamos).
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    for (final k in [_dek, sqlcipher, files, thumbs]) {
      k.destroy();
    }
  }

  void _checkAlive() {
    if (_destroyed) throw StateError('La jerarquía de llaves fue destruida');
  }
}
