import 'dart:io';
import 'dart:typed_data';

/// Cuenta de nube conectada.
class CloudAccount {
  const CloudAccount({required this.email, this.displayName, this.id});
  final String email;
  final String? displayName;

  /// Id estable de la cuenta (Google: `GoogleSignInAccount.id`), o `null`.
  /// Solo se usa para calcular el tag de cuenta (D75); nunca se registra.
  final String? id;
}

/// Cuota de almacenamiento (about.get -> storageQuota). [limitBytes] es
/// `null` si la cuenta no tiene límite.
class CloudQuota {
  const CloudQuota({required this.usedBytes, this.limitBytes});
  final int usedBytes;
  final int? limitBytes;

  double? get fraction => limitBytes == null || limitBytes == 0
      ? null
      : (usedBytes / limitBytes!).clamp(0.0, 1.0);
}

/// Metadatos de un archivo remoto.
class CloudFile {
  const CloudFile({
    required this.id,
    required this.name,
    required this.size,
    this.md5Checksum,
  });
  final String id;
  final String name;
  final int size;

  /// MD5 hex que calcula Drive (solo archivos binarios).
  final String? md5Checksum;
}

/// Token de cancelación de una subida/descarga.
class CloudCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

typedef CloudProgress = void Function(int transferred, int total);

/// Errores tipados del almacenamiento en la nube.
sealed class CloudException implements Exception {
  const CloudException(this.message);
  final String message;

  /// `true` si reintentar más tarde puede funcionar sin intervención.
  bool get isTransient => false;

  @override
  String toString() => '$runtimeType: $message';
}

/// Sin conexión / DNS / timeout.
class CloudNoNetworkException extends CloudException {
  const CloudNoNetworkException([super.message = 'Sin conexión a internet']);
  @override
  bool get isTransient => true;
}

/// No hay sesión de Google, o el token caducó/fue revocado (401).
class CloudNotAuthenticatedException extends CloudException {
  const CloudNotAuthenticatedException([
    super.message = 'Inicia sesión con Google para sincronizar',
  ]);
}

/// Falló el inicio de sesión (configuración OAuth, consentimiento, etc.).
/// [code] es el código del plugin (p. ej. `sign_in_failed`) si existe.
class CloudSignInFailedException extends CloudException {
  const CloudSignInFailedException(super.message, {this.code});
  final String? code;
}

/// El usuario canceló el inicio de sesión.
class CloudSignInCancelledException extends CloudException {
  const CloudSignInCancelledException([
    super.message = 'Inicio de sesión cancelado',
  ]);
}

/// D78: el selector de cuentas de Google no respondió en el plazo
/// (`GuardedSignIn`). La espera se libera; un resultado tardío se ignora.
class CloudSignInTimeoutException extends CloudException {
  const CloudSignInTimeoutException([
    super.message =
        'El selector de Google no respondió. Vuelve a intentarlo; si se '
        'repite, cierra Kern del todo y ábrela de nuevo.',
  ]);
}

/// Cuenta de Drive sin espacio (403 storageQuotaExceeded).
class CloudQuotaExceededException extends CloudException {
  const CloudQuotaExceededException([
    super.message = 'Tu Google Drive no tiene espacio suficiente',
  ]);
}

/// 403 sin ser de cuota (permisos, API deshabilitada, límite de tasa...).
class CloudForbiddenException extends CloudException {
  const CloudForbiddenException(super.message, {this.rateLimited = false});

  /// Límite de peticiones: se reintenta con espera.
  final bool rateLimited;
  @override
  bool get isTransient => rateLimited;
}

/// 5xx de Drive.
class CloudServerException extends CloudException {
  const CloudServerException(this.status, [String? message])
    : super(message ?? 'Error del servidor de Drive ($status)');
  final int status;
  @override
  bool get isTransient => true;
}

/// 404: el archivo remoto no existe.
class CloudNotFoundException extends CloudException {
  const CloudNotFoundException([super.message = 'No existe en la nube']);
}

/// Operación cancelada por el llamador.
class CloudCancelledException extends CloudException {
  const CloudCancelledException([super.message = 'Cancelado']);
}

/// S-14: el archivo remoto (declarado o recibido) supera el tope permitido.
class CloudTooLargeException extends CloudException {
  const CloudTooLargeException([
    super.message = 'El archivo de la nube supera el tamaño permitido',
  ]);
}

/// Fase 8 (D67/D68): la nube no está disponible porque la bóveda abierta es
/// la secundaria (`SlotGuardedCloudStorage`). Mensaje neutro (M8).
class CloudSlotException extends CloudException {
  const CloudSlotException([super.message = 'No disponible']);
}

/// Cualquier otro error inesperado.
class CloudUnknownException extends CloudException {
  const CloudUnknownException(super.message);
}

/// Almacenamiento en la nube (Drive appDataFolder) detrás de una interfaz
/// para poder inyectar un fake en las pruebas.
///
/// Todas las operaciones lanzan subtipos de [CloudException].
abstract interface class CloudStorage {
  /// Correo de la cuenta conectada, o `null`.
  String? get currentAccountEmail;

  /// Id estable de la cuenta conectada (Google: `GoogleSignInAccount.id`), o
  /// `null` (sin sesión o desconocido: el tag usa entonces el correo). Nunca
  /// se registra ni se guarda en claro (D75).
  String? get currentAccountId;

  /// Inicio de sesión interactivo.
  Future<CloudAccount> signIn();

  /// Restaura la sesión sin interacción; `null` si no hay.
  Future<CloudAccount?> signInSilently();

  Future<void> signOut();

  Future<CloudQuota> getQuota();

  /// Sube [file] por chunks (subida resumible) con [onProgress] y
  /// [cancel]. Si [replaceFileId] no es null, reemplaza ese archivo.
  Future<CloudFile> uploadFile({
    required File file,
    required String name,
    String? replaceFileId,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  });

  /// Sube/reemplaza un blob pequeño (JSON de respaldo, etc.).
  Future<CloudFile> uploadBytes({
    required Uint8List bytes,
    required String name,
    String? replaceFileId,
  });

  Future<CloudFile> getMetadata(String fileId);

  /// Cambia solo el NOMBRE de [fileId] (metadatos; el contenido y sus
  /// revisiones no cambian). Lo usa la cuarentena de la rotación (M6).
  Future<CloudFile> rename(String fileId, String newName);

  /// Descarga a [destination]. Si [maxBytes] no es null y el tamaño declarado
  /// o los bytes recibidos lo superan, aborta, borra lo escrito y lanza
  /// [CloudTooLargeException] (S-14).
  Future<void> download(
    String fileId,
    File destination, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
    int? maxBytes,
  });

  /// Descarga en memoria. Con [maxBytes] lanza [CloudTooLargeException] si el
  /// tamaño declarado en los metadatos o los bytes recibidos lo superan,
  /// cortando la lectura en cuanto se excede (S-14).
  Future<Uint8List> downloadBytes(String fileId, {int? maxBytes});

  Future<void> delete(String fileId);

  /// Busca por nombre exacto en appDataFolder (el más reciente), o `null`.
  Future<CloudFile?> findByName(String name);

  /// Lista todo el appDataFolder.
  Future<List<CloudFile>> list();
}
