import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;

/// AES-256-GCM con nonce de 96 bits y tag de 128 bits (D22).
///
/// Todas las implementaciones son el MISMO algoritmo estándar (NIST SP
/// 800-38D): para la misma llave, nonce, AAD y texto dan exactamente los
/// mismos bytes. El formato `.vault` v2, las envolturas de la DEK y los
/// textos de `CryptoService` no dependen del backend (verificado con vectores
/// en `test/aes_gcm_backend_test.dart` y nativo↔Dart en
/// `integration_test/aes_native_test.dart`).
///
/// Contrato de errores (idéntico en todos los backends):
/// * Tag inválido (llave incorrecta, datos/AAD/nonce alterados) →
///   [SecretBoxAuthenticationError]. Los llamadores lo traducen
///   (`VaultAuthException`, `null` en `WrappedKey.unwrap`).
/// * Llave destruida → [StateError]; llave/nonce de longitud incorrecta →
///   [ArgumentError]. Se comprueban ANTES de llamar al nativo, así que no se
///   confunden con un fallo de la plataforma.
///
/// Selección ([AesGcmBackend.current]):
/// * Android / iOS → [FallbackAesGcmBackend] (nativo [NativeAesGcmBackend]
///   para datos ≥ [FallbackAesGcmBackend.minNativeLength]; si el canal falla,
///   Dart para el resto de la sesión).
/// * Escritorio, `flutter test`, isolates secundarios → [DartAesGcmBackend].
/// * `--dart-define=VAULT_AES_BACKEND=dart` → [DartAesGcmBackend] siempre.
/// * Las pruebas pueden fijar otro con [AesGcmBackend.current] = ….
abstract interface class AesGcmBackend {
  static const int keyLength = 32;
  static const int nonceLength = 12;
  static const int macLength = 16;

  /// Nombre corto para logs y pruebas.
  String get name;

  /// Cifra [clearText] con [nonce] (12 bytes) y [aad].
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  });

  /// Verifica el tag y descifra. Tag inválido → [SecretBoxAuthenticationError].
  /// Nunca devuelve texto sin autenticar.
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  });

  static AesGcmBackend? _current;

  /// Backend en uso. Se crea perezosamente con [platformDefault]. Se resuelve
  /// en cada operación (no se guarda en campos estáticos de los llamadores),
  /// así que da igual cuándo se instancien éstos.
  static AesGcmBackend get current => _current ??= platformDefault();

  /// Permite inyectar otro backend (pruebas). `null` vuelve al de plataforma.
  static set current(AesGcmBackend? backend) => _current = backend;

  /// Forzado en compilación: `--dart-define=VAULT_AES_BACKEND=dart` usa solo
  /// Dart (diagnóstico / medir el "antes"); vacío o `auto` = por plataforma.
  static const String forced = String.fromEnvironment('VAULT_AES_BACKEND');

  /// Backend por defecto según la plataforma (ver documentación de la clase).
  static AesGcmBackend platformDefault() {
    if (kIsWeb || forced == 'dart') return DartAesGcmBackend();
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return DartAesGcmBackend();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return FallbackAesGcmBackend(
        primary: NativeAesGcmBackend(),
        fallback: DartAesGcmBackend(),
      );
    }
    return DartAesGcmBackend();
  }
}

/// AES-GCM en Dart puro ([DartAesGcm] de `cryptography`) en el isolate que
/// llama. Es la referencia y el respaldo.
class DartAesGcmBackend implements AesGcmBackend {
  DartAesGcmBackend();

  final DartAesGcm _aes = DartAesGcm(
    secretKeyLength: AesGcmBackend.keyLength,
    nonceLength: AesGcmBackend.nonceLength,
  );

  @override
  String get name => 'dart';

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  }) => _aes.encrypt(clearText, secretKey: secretKey, nonce: nonce, aad: aad);

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  }) => _aes.decrypt(secretBox, secretKey: secretKey, aad: aad);
}

/// AES-GCM del sistema operativo a través del plugin `cryptography_flutter`
/// 2.3.4: Android `javax.crypto` "AES/GCM/NoPadding" (Conscrypt/BoringSSL),
/// iOS CryptoKit `AES.GCM` (iOS 13+). Los datos viajan por MethodChannel
/// (copia de ida y vuelta) y el cálculo corre en el hilo de plataforma.
///
/// Solo está disponible en el isolate principal de la app (el plugin se
/// registra allí antes de `main`). Si no lo está lanza [UnsupportedError]
/// sin tocar nada; [FallbackAesGcmBackend] lo usa para caer a Dart.
class NativeAesGcmBackend implements AesGcmBackend {
  NativeAesGcmBackend();

  // Política: todo tamaño va al canal (el umbral lo decide
  // FallbackAesGcmBackend). maxLength = cola del plugin (20 MB en Android);
  // los bloques .vault son ≤ 16 MiB.
  late final FlutterAesGcm _aes = FlutterAesGcm(
    secretKeyLength: AesGcmBackend.keyLength,
    channelPolicy: CryptographyChannelPolicy(
      minLength: 0,
      maxLength: CryptographyChannelQueue.defaultInstance.maxConcurrentSize,
    ),
    // Solo se usa si la plataforma responde UNSUPPORTED_ALGORITHM; mismo
    // resultado (algoritmo estándar), en este isolate (sin compute).
    fallback: DartAesGcm(
      secretKeyLength: AesGcmBackend.keyLength,
      nonceLength: AesGcmBackend.nonceLength,
    ),
  );

  @override
  String get name => 'native';

  /// `true` si el plugin está registrado en este isolate y la plataforma
  /// tiene implementación (Android o iOS/macOS).
  bool get isAvailable =>
      !kIsWeb &&
      FlutterCryptography.isPluginPresent &&
      _aes.isSupportedPlatform;

  /// `true` si [length] bytes irán realmente al canal nativo.
  bool handlesLength(int length) =>
      isAvailable && _aes.channelPolicy.matches(length: length);

  void _check(int length) {
    if (!handlesLength(length)) {
      throw UnsupportedError('AES-GCM nativo no disponible aquí');
    }
  }

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  }) {
    _check(clearText.length);
    return _aes.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  }) {
    _check(secretBox.cipherText.length);
    return _aes.decrypt(secretBox, secretKey: secretKey, aad: aad);
  }
}

/// Usa [primary] (nativo) y, si el canal falla, [fallback] (Dart).
///
/// * Datos de menos de [minNativeLength] bytes (envolturas de la DEK, textos
///   cortos) van directo a [fallback]: el viaje por el canal cuesta más que
///   el cálculo.
/// * Las entradas se validan aquí primero (llave extraíble de 32 bytes,
///   nonce de 12, tag de 16), igual para ambos backends: esos errores se
///   propagan tal cual y NO desactivan el nativo.
/// * [SecretBoxAuthenticationError] del nativo se propaga tal cual (no se
///   reintenta con Dart: el tag es determinista).
/// * Cualquier otro error del nativo (PlatformException, MissingPlugin,
///   comprobación de longitud del paquete…) se considera fallo de la
///   plataforma: la operación se repite con [fallback] y el nativo queda
///   desactivado durante la sesión. Repetir un cifrado con el mismo nonce es
///   seguro: mismos llave/nonce/AAD/texto ⇒ mismos bytes (no hay reuso de
///   nonce con textos distintos).
class FallbackAesGcmBackend implements AesGcmBackend {
  FallbackAesGcmBackend({
    required this.primary,
    required this.fallback,
    this.minNativeLength = defaultMinNativeLength,
  });

  static const int defaultMinNativeLength = 1024;

  final AesGcmBackend primary;
  final AesGcmBackend fallback;
  final int minNativeLength;
  bool _primaryBroken = false;

  /// Backend que resolvió la última operación (diagnóstico/pruebas).
  String? lastUsed;

  /// Si el nativo quedó desactivado por un fallo.
  bool get primaryBroken => _primaryBroken;

  @override
  String get name => '${primary.name}|${fallback.name}';

  bool _usePrimary(int length) {
    if (_primaryBroken || length < minNativeLength) return false;
    final p = primary;
    return p is! NativeAesGcmBackend || p.handlesLength(length);
  }

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  }) async {
    if (nonce.length != AesGcmBackend.nonceLength) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Se esperaban 12 bytes');
    }
    if (_usePrimary(clearText.length)) {
      final key = await _stableKey(secretKey);
      try {
        final box = await primary.encrypt(
          clearText,
          secretKey: key,
          nonce: nonce,
          aad: aad,
        );
        _checkBox(box, clearText.length);
        lastUsed = primary.name;
        return box;
      } on SecretBoxAuthenticationError {
        rethrow;
      } catch (e) {
        _disable(e);
      } finally {
        key.destroy();
      }
    }
    final box = await fallback.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );
    lastUsed = fallback.name;
    return box;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  }) async {
    if (secretBox.nonce.length != AesGcmBackend.nonceLength) {
      throw ArgumentError.value(
        secretBox.nonce.length,
        'nonce',
        'Se esperaban 12 bytes',
      );
    }
    if (secretBox.mac.bytes.length != AesGcmBackend.macLength) {
      // Igual que DartAesGcm: un tag de otra longitud no autentica.
      throw SecretBoxAuthenticationError();
    }
    if (_usePrimary(secretBox.cipherText.length)) {
      final key = await _stableKey(secretKey);
      try {
        final clear = await primary.decrypt(
          secretBox,
          secretKey: key,
          aad: aad,
        );
        if (clear.length != secretBox.cipherText.length) {
          throw StateError('AES-GCM nativo: longitud de salida inesperada');
        }
        lastUsed = primary.name;
        return clear;
      } on SecretBoxAuthenticationError {
        lastUsed = primary.name;
        rethrow;
      } catch (e) {
        _disable(e);
      } finally {
        key.destroy();
      }
    }
    final clear = await fallback.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
    );
    lastUsed = fallback.name;
    return clear;
  }

  /// Extrae la llave una sola vez (StateError si está destruida, como en
  /// Dart) y entrega al nativo una COPIA propia que se sobrescribe al
  /// terminar. Así un `destroy()` concurrente (bloqueo de la bóveda) ni hace
  /// fallar al nativo a mitad (lo desactivaría por error) ni le deja cifrar
  /// con un búfer ya puesto a cero.
  static Future<SecretKeyData> _stableKey(SecretKey key) async {
    final bytes = await key.extractBytes();
    if (bytes.length != AesGcmBackend.keyLength) {
      throw ArgumentError('La llave AES-GCM debe medir 32 bytes');
    }
    return SecretKeyData(
      Uint8List.fromList(bytes),
      overwriteWhenDestroyed: true,
    );
  }

  static void _checkBox(SecretBox box, int clearLength) {
    if (box.cipherText.length != clearLength ||
        box.mac.bytes.length != AesGcmBackend.macLength) {
      throw StateError('AES-GCM nativo: salida de cifrado inesperada');
    }
  }

  void _disable(Object e) {
    _primaryBroken = true;
    if (kDebugMode) {
      debugPrint(
        '[vault-crypto] AES-GCM: ${primary.name} falló (${e.runtimeType}); '
        'uso ${fallback.name} el resto de la sesión',
      );
    }
  }
}

/// Configuración criptográfica al arrancar (llamar en `main` antes de usar
/// cualquier primitiva).
///
/// * El plugin `cryptography_flutter` se registra solo (dartPluginClass,
///   antes de `main`) y cambia `Cryptography.instance` a su implementación,
///   lo que redirigiría en silencio también HMAC/HKDF. Aquí se restaura la
///   instancia original de `package:cryptography`: el ÚNICO cambio de
///   backend es AES-GCM, y es explícito vía [AesGcmBackend] (D22).
///   (`FlutterCryptography.enable()` está obsoleto en 2.3.x y además
///   congelaría la instancia del plugin, justo lo contrario.)
/// * Crea ya el [AesGcmBackend] de plataforma y deja constancia en el log
///   de depuración (sin datos sensibles).
void configureCryptography() {
  try {
    Cryptography.instance = Cryptography.defaultInstance;
  } on StateError {
    // Otra parte congeló una instancia: se respeta (no afecta a AES-GCM,
    // que no pasa por Cryptography.instance).
  }
  final backend = AesGcmBackend.current;
  if (kDebugMode) {
    final native =
        backend is FallbackAesGcmBackend &&
            backend.primary is NativeAesGcmBackend
        ? (backend.primary as NativeAesGcmBackend).isAvailable
        : false;
    debugPrint(
      '[vault-crypto] AES-GCM backend=${backend.name} nativoDisponible=$native',
    );
  }
}
