import '../../core/security/auto_lock.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/session/vault_session.dart';
import '../../core/services/app_paths.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';

class VaultImportService {
  final CryptoService _cryptoService = CryptoService();
  final VaultDataRepository _repo = VaultDataRepository();

  /// Abre el explorador de archivos, cifra por bloques, guarda en la BD
  /// y NUNCA borra el original (ver [deleteOriginal]).
  Future<bool> importAndEncryptFile({
    required String? targetFolderId,
    @Deprecated('Se ignora: el original nunca se borra al importar.')
    bool deleteOriginal = false,
  }) async {
    try {
      // 1. Verificar sesión activa
      // Subllave "files" de la jerarquía (HKDF de la DEK), no la DEK.
      final filesKey = VaultSession().filesKey;
      if (filesKey == null) return false;

      // 2. Seleccionar archivo
      FilePickerResult? result = await AutoLockSuspension.instance.run(
        () => FilePicker.platform.pickFiles(allowMultiple: false),
      );

      if (result == null || result.files.single.path == null) return false;

      final sourcePath = result.files.single.path!;
      final fileName = result.files.single.name;
      final fileSize = result.files.single.size;
      final sourceFile = File(sourcePath);

      // 3. Preparar ruta destino interna (.vault)
      await AppPaths.init();
      final itemId = const Uuid().v4();
      // En la BD solo va la ruta RELATIVA (vault/<id>.vault).
      final relativePath = AppPaths.vaultRelativePath(itemId);
      final destFile = AppPaths.resolve(relativePath);

      // SHA-256 del contenido original (streaming).
      final sink = Sha256().newHashSink();
      await for (final chunk in sourceFile.openRead()) {
        sink.add(chunk);
      }
      sink.close();
      final contentHash = (await sink.hash()).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // 4. Cifrar en formato .vault v2 (bloques de 1 MiB, streaming).
      // Si falla, encryptFile borra el destino parcial y lanza excepción.
      await _cryptoService.encryptFile(sourceFile, destFile, filesKey);

      // Verificar que el archivo cifrado realmente se creó en el sandbox
      if (!await destFile.exists()) return false;

      // 5. Registrar en SQLCipher
      final itemModel = VaultItemModel(
        id: itemId,
        name: fileName,
        folderId: targetFolderId,
        encryptedPath: relativePath,
        fileSize: fileSize,
        mimeType: result.files.single.extension ?? 'unknown',
        createdAt: DateTime.now().toIso8601String(),
        syncStatus: SyncStatus.pendiente,
        contentHash: contentHash,
      );

      await _repo.insertItem(itemModel);

      // 6. El original NUNCA se borra aquí: el selector entrega una copia (el
      // borrado real de originales exige verificar la copia en la nube y la
      // confirmación del usuario; ver `GalleryImportService`). [deleteOriginal]
      // se ignora a propósito.

      return true;
    } catch (e) {
      debugPrint('Error al importar y cifrar archivo: $e');
      return false;
    }
  }
}
