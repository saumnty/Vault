import 'dart:io';

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
    int Function()? keyGen,
    CryptoService? crypto,
    VaultDataRepository? repository,
    VaultPaths? paths,
    SessionTicket? Function()? sessionTicket,
  }) : _picker = picker ?? PlatformDocumentPicker(),
       // D67: por defecto, la llave de la sesión global solo si la bóveda
       // abierta es la de [paths] (la principal salvo que se indique otra).
       _filesKey =
           filesKey ??
           (() {
             final s = VaultSession();
             return s.isUnlockedAs((paths ?? VaultPaths.primary).slot)
                 ? s.filesKey
                 : null;
           }),
       _keyGen =
           keyGen ??
           (filesKey == null ? (() => VaultSession().currentGen) : (() => 1)),
       _cryptoService = crypto ?? CryptoService(),
       _repo = repository ?? VaultDataRepository(),
       _paths = paths ?? VaultPaths.primary,
       _ticket =
           sessionTicket ??
           (filesKey == null
               ? (() {
                   final s = VaultSession();
                   return s.isUnlockedAs((paths ?? VaultPaths.primary).slot)
                       ? s.ticket()
                       : null;
                 })
               : null);

  /// Rutas de la bóveda a la que importa (D67).
  final VaultPaths _paths;

  /// D67: ticket de la sesión de SU bóveda, capturado ANTES de abrir el
  /// selector y comprobado antes de escribir el `.vault` y la fila. `null`
  /// (pruebas con llave inyectada) = sin esta guarda.
  final SessionTicket? Function()? _ticket;

  final DocumentPicker _picker;
  final SecretKey? Function() _filesKey;

  /// Generación de llave de [_filesKey] (D60). Por defecto la de la sesión
  /// global; con una llave inyectada (pruebas) y sin generación, la 1.
  final int Function() _keyGen;
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
    File? destFile;
    var committed = false;
    try {
      // 1. Verificar sesión activa
      // Subllave "files" de la jerarquía (HKDF de la DEK), no la DEK.
      // Llave y su generación, leídas juntas (sin `await` en medio).
      final gen = _keyGen();
      final filesKey = _filesKey();
      if (filesKey == null) return false;
      // D67: bóveda y época al empezar (antes del selector).
      final provider = _ticket;
      final SessionTicket? ticket = provider == null ? null : provider();
      if (provider != null && ticket == null) return false;
      bool stale() => ticket != null && !ticket.isValid;

      // 2. Seleccionar archivo
      picked = await _picker.pick();
      if (picked == null || stale()) return false;

      // 3. Preparar ruta destino interna (.vault)
      await AppPaths.init();
      final itemId = const Uuid().v4();
      // En la BD solo va la ruta RELATIVA (vault/<id>.vault).
      final relativePath = AppPaths.vaultRelativePath(itemId, gen: gen);
      final dest = destFile = _paths.resolve(relativePath);
      if (stale()) return false;

      // 4. Cifrar en formato .vault v2 (bloques de 1 MiB, streaming) y, de
      // paso, SHA-256 del contenido original. Si falla, el destino parcial se
      // borra y se lanza la excepción.
      final source = _HashingSource(picked);
      final fileHeader = await _cryptoService.encryptSource(
        source,
        dest,
        filesKey,
      );
      final contentHash = await source.hexDigest();

      // Verificar que el archivo cifrado realmente se creó en el sandbox
      if (!await dest.exists()) return false;
      // D67: sin fila en la BD de otra sesión (el `.vault` se borra abajo).
      if (stale()) return false;

      // 5. Registrar en SQLCipher
      final itemModel = VaultItemModel(
        // D60: la generación de la llave con que se cifró.
        keyGen: gen,
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
      committed = true;

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
      // Sin fila no queda un `.vault` huérfano (siempre en SU bóveda).
      final f = destFile;
      if (!committed && f != null) {
        try {
          if (await f.exists()) await f.delete();
        } on FileSystemException {
          // best-effort
        }
      }
    }
  }
}
