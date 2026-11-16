import '../../core/security/auto_lock.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/session/vault_session.dart';
import '../../core/services/app_paths.dart';
import '../../core/services/plain_residue.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';

/// Archivo elegido en el selector del sistema (una COPIA privada del plugin).
typedef PickedSourceFile = ({
  String path,
  String name,
  int size,
  String? extension,
});

class VaultImportService {
  /// Todo es inyectable para pruebas; por defecto: selector `file_picker`,
  /// subllave "files" de la sesión global, repositorio real y las carpetas
  /// de copias de [PlainResidue.pickerCopyRoots].
  VaultImportService({
    Future<PickedSourceFile?> Function()? pickFile,
    Future<List<Directory>> Function()? pickerCopyRoots,
    SecretKey? Function()? filesKey,
    CryptoService? crypto,
    VaultDataRepository? repository,
  }) : _pickFile = pickFile ?? _systemPicker,
       _pickerCopyRoots = pickerCopyRoots ?? PlainResidue.pickerCopyRoots,
       _filesKey = filesKey ?? (() => VaultSession().filesKey),
       _cryptoService = crypto ?? CryptoService(),
       _repo = repository ?? VaultDataRepository();

  final Future<PickedSourceFile?> Function() _pickFile;
  final Future<List<Directory>> Function() _pickerCopyRoots;
  final SecretKey? Function() _filesKey;
  final CryptoService _cryptoService;
  final VaultDataRepository _repo;

  static Future<PickedSourceFile?> _systemPicker() async {
    final result = await AutoLockSuspension.instance.run(
      () => FilePicker.platform.pickFiles(allowMultiple: false),
    );
    final f = result?.files.single;
    final path = f?.path;
    if (f == null || path == null) return null;
    return (path: path, name: f.name, size: f.size, extension: f.extension);
  }

  /// Abre el explorador de archivos, cifra por bloques, guarda en la BD
  /// y NUNCA borra el original (ver [deleteOriginal]).
  ///
  /// S-02 (revisión de seguridad): el selector entrega una COPIA EN CLARO en
  /// la caché de la app (Android: `cache/file_picker/<ms>/<nombre>`; iOS:
  /// `tmp/`). Esa copia se borra SIEMPRE al terminar (éxito o fallo); solo
  /// si está dentro de esas carpetas del plugin, nunca un archivo del usuario.
  Future<bool> importAndEncryptFile({
    required String? targetFolderId,
    @Deprecated('Se ignora: el original nunca se borra al importar.')
    bool deleteOriginal = false,
  }) async {
    String? pickedPath;
    try {
      // 1. Verificar sesión activa
      // Subllave "files" de la jerarquía (HKDF de la DEK), no la DEK.
      final filesKey = _filesKey();
      if (filesKey == null) return false;

      // 2. Seleccionar archivo
      final picked = await _pickFile();
      if (picked == null) return false;
      pickedPath = picked.path;

      final sourcePath = picked.path;
      final fileName = picked.name;
      final fileSize = picked.size;
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
      final fileHeader = await _cryptoService.encryptFile(
        sourceFile,
        destFile,
        filesKey,
      );

      // Verificar que el archivo cifrado realmente se creó en el sandbox
      if (!await destFile.exists()) return false;

      // 5. Registrar en SQLCipher
      final itemModel = VaultItemModel(
        id: itemId,
        name: fileName,
        folderId: targetFolderId,
        encryptedPath: relativePath,
        fileSize: fileSize,
        mimeType: picked.extension ?? 'unknown',
        createdAt: DateTime.now().toIso8601String(),
        syncStatus: SyncStatus.pendiente,
        contentHash: contentHash,
        fileId: fileHeader.fileIdString,
      );

      await _repo.insertItem(itemModel);

      // 6. El original NUNCA se borra aquí: el selector entrega una copia (el
      // borrado real de originales exige verificar la copia en la nube y la
      // confirmación del usuario; ver `GalleryImportService`). [deleteOriginal]
      // se ignora a propósito.

      return true;
    } catch (e) {
      // Sin `$e`: el mensaje de un FileSystemException incluye la ruta, y la
      // ruta de la copia lleva el NOMBRE ORIGINAL del archivo (debugPrint
      // también imprime en release).
      debugPrint('Error al importar y cifrar archivo: ${e.runtimeType}');
      return false;
    } finally {
      final path = pickedPath;
      if (path != null) {
        try {
          await PlainResidue.deletePickerCopy(path, await _pickerCopyRoots());
        } on Object {
          // Mejor esfuerzo: se barre al arrancar (PlainResidue.sweepAtStartup).
        }
      }
    }
  }
}
