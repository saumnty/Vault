import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/session/vault_session.dart';
import '../repositories/vault_database.dart';

class VaultImportService {
  final CryptoService _cryptoService = CryptoService();
  final VaultDatabase _vaultDatabase = VaultDatabase();

  /// Abre el explorador de archivos, cifra por bloques, guarda en la BD
  /// y opcionalmente borra el archivo original de la galería pública.
  Future<bool> importAndEncryptFile({
    required String? targetFolderId,
    bool deleteOriginal = false, // <-- Bandera para borrar el original
  }) async {
    try {
      // 1. Verificar sesión activa
      // Subllave "files" de la jerarquía (HKDF de la DEK), no la DEK.
      final filesKey = VaultSession().filesKey;
      if (filesKey == null) return false;

      // 2. Seleccionar archivo
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
      );

      if (result == null || result.files.single.path == null) return false;

      final sourcePath = result.files.single.path!;
      final fileName = result.files.single.name;
      final fileSize = result.files.single.size;
      final sourceFile = File(sourcePath);

      // 3. Preparar ruta destino interna (.vault)
      final appDir = await getApplicationDocumentsDirectory();
      final itemId = const Uuid().v4();
      final destFilePath = '${appDir.path}/$itemId.vault';
      final destFile = File(destFilePath);

      // 4. Cifrar en formato .vault v2 (bloques de 1 MiB, streaming).
      // Si falla, encryptFile borra el destino parcial y lanza excepción.
      await _cryptoService.encryptFile(sourceFile, destFile, filesKey);

      // Verificar que el archivo cifrado realmente se creó en el sandbox
      if (!await destFile.exists()) return false;

      // 5. Registrar en SQLCipher
      final db = await _vaultDatabase.database;
      final itemModel = VaultItemModel(
        id: itemId,
        name: fileName,
        folderId: targetFolderId,
        encryptedPath: destFilePath,
        fileSize: fileSize,
        mimeType: result.files.single.extension ?? 'unknown',
        createdAt: DateTime.now().toIso8601String(),
        isOffline: 0,
      );

      await _vaultDatabase.insertItem(db, itemModel);

      // 6. Si el usuario activó la opción, borrar el archivo original de la galería
      if (deleteOriginal) {
        try {
          if (await sourceFile.exists()) {
            await sourceFile.delete();
          }
        } catch (e) {
          debugPrint('No se pudo borrar el archivo original del sistema: $e');
        }
      }

      return true;
    } catch (e) {
      debugPrint('Error al importar y cifrar archivo: $e');
      return false;
    }
  }
}