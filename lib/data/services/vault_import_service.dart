import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/vault_file_format.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/vault_session.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../picker/document_picker.dart';
import '../repositories/vault_data_repository.dart';

/// Envuelve un [VaultByteSource] calculando el SHA-256 y contando los bytes
/// del contenido en claro MIENTRAS se cifra (una sola lectura).
class _HashingSource implements VaultByteSource {
  _HashingSource(this._inner) : _sink = Sha256().newHashSink();

  final VaultByteSource _inner;
  final HashSink _sink;
  int bytes = 0;

  @override
  Future<Uint8List> read(int length) async {
    final chunk = await _inner.read(length);
    if (chunk.isNotEmpty) {
      _sink.add(chunk);
      bytes += chunk.length;
    }
    return chunk;
  }

  Future<String> hexDigest() async {
    _sink.close();
    return (await _sink.hash()).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class VaultImportService {
  /// Todo es inyectable para pruebas; por defecto: selector propio
  /// [PlatformDocumentPicker] (sin copia en claro), subllave "files" de la
  /// sesión global y repositorio real.
  VaultImportService({
    DocumentPicker? picker,
    SecretKey? Function()? filesKey,
    CryptoService? crypto,
    VaultDataRepository? repository,
  }) : _picker = picker ?? PlatformDocumentPicker(),
       _filesKey = filesKey ?? (() => VaultSession().filesKey),
       _cryptoService = crypto ?? CryptoService(),
       _repo = repository ?? VaultDataRepository();

  final DocumentPicker _picker;
  final SecretKey? Function() _filesKey;
  final CryptoService _cryptoService;
  final VaultDataRepository _repo;

  /// Abre el explorador de archivos, cifra por bloques LEYENDO DEL PROVEEDOR
  /// (sin copiar el archivo a disco: S-02 cerrado de raíz), guarda en la BD y
  /// NUNCA borra el original (ver [deleteOriginal]).
  Future<bool> importAndEncryptFile({
    required String? targetFolderId,
    @Deprecated('Se ignora: el original nunca se borra al importar.')
    bool deleteOriginal = false,
  }) async {
    PickedDocument? picked;
    try {
      // 1. Verificar sesión activa
      // Subllave "files" de la jerarquía (HKDF de la DEK), no la DEK.
      final filesKey = _filesKey();
      if (filesKey == null) return false;

      // 2. Seleccionar archivo
      picked = await _picker.pick();
      if (picked == null) return false;

      // 3. Preparar ruta destino interna (.vault)
      await AppPaths.init();
      final itemId = const Uuid().v4();
      // En la BD solo va la ruta RELATIVA (vault/<id>.vault).
      final relativePath = AppPaths.vaultRelativePath(itemId);
      final destFile = AppPaths.resolve(relativePath);

      // 4. Cifrar en formato .vault v2 (bloques de 1 MiB, streaming) y, de
      // paso, SHA-256 del contenido original. Si falla, el destino parcial se
      // borra y se lanza la excepción.
      final source = _HashingSource(picked);
      final fileHeader = await _cryptoService.encryptSource(
        source,
        destFile,
        filesKey,
      );
      final contentHash = await source.hexDigest();

      // Verificar que el archivo cifrado realmente se creó en el sandbox
      if (!await destFile.exists()) return false;

      // 5. Registrar en SQLCipher
      final itemModel = VaultItemModel(
        // D60: cifrado con la llave de la sesión, que hoy es siempre la de
        // la generación 1 (el keyring por generación llega con la rotación).
        keyGen: 1,
        id: itemId,
        name: picked.name,
        folderId: targetFolderId,
        encryptedPath: relativePath,
        fileSize: source.bytes,
        mimeType: picked.extension ?? 'unknown',
        createdAt: DateTime.now().toIso8601String(),
        syncStatus: SyncStatus.pendiente,
        contentHash: contentHash,
        fileId: fileHeader.fileIdString,
      );

      await _repo.insertItem(itemModel);

      // 6. El original NUNCA se borra aquí: el borrado real de originales
      // exige verificar la copia en la nube y la confirmación del usuario;
      // ver `GalleryImportService`. [deleteOriginal] se ignora a propósito.
      return true;
    } catch (e) {
      // Sin `$e`: el mensaje de un FileSystemException incluye la ruta y
      // debugPrint también imprime en release.
      debugPrint('Error al importar y cifrar archivo: ${e.runtimeType}');
      return false;
    } finally {
      await picked?.close();
    }
  }
}
