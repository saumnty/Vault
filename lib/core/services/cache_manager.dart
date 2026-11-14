import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../data/repositories/vault_database.dart'; // Asegúrate de importar tu ruta correcta a la BD

class CacheManager {
  static final CacheManager instance = CacheManager._init();
  CacheManager._init();

  // Límite máximo de caché local (Ejemplo: 500 MB)
  static const int maxCacheSizeBytes = 500 * 1024 * 1024;

  Future<Directory> getCacheDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/vault_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  /// Verifica si la caché excede el límite y borra los archivos más antiguos (LRU),
  /// omitiendo aquellos que estén marcados como 'isOffline' en SQLCipher.
  Future<void> enforceLruLimit() async {
    final cacheDir = await getCacheDirectory();
    if (!await cacheDir.exists()) return;

    final files = cacheDir.listSync().whereType<File>().toList();
    int totalSize = 0;

    // Calcular tamaño total de la caché
    for (var file in files) {
      totalSize += await file.length();
    }

    // Si superamos el límite, ordenamos por última fecha de acceso (más antiguo primero)
    if (totalSize > maxCacheSizeBytes) {
      files.sort((a, b) {
        final statA = a.statSync();
        final statB = b.statSync();
        return statA.accessed.compareTo(statB.accessed);
      });

      // Abrir conexión a la base de datos para verificar el estado de cada archivo
      // TODO(F3): columnas localPath/originalName aún no existen en el esquema.
      final db = await VaultDatabase.instance.database;

      // Eliminar archivos hasta liberar espacio
      for (var file in files) {
        if (totalSize <= maxCacheSizeBytes) break;

        // Extraer el nombre del archivo o ID guardado en caché
        final fileName = file.uri.pathSegments.last;
        // Limpiamos prefijos temporales si los hubiera (ej: 'plain_' o 'enc_')
        final cleanName = fileName.replaceFirst(RegExp(r'^(plain_|enc_)'), '');

        // Consultar en SQLCipher si este archivo está marcado como offline permanente
        final result = await db.query(
          'vault_items',
          where: 'localPath LIKE ? OR originalName = ?',
          whereArgs: ['%$cleanName%', cleanName],
          limit: 1,
        );

        bool isOfflineProtected = false;
        if (result.isNotEmpty) {
          isOfflineProtected = result.first['isOffline'] == 1;
        }

        // Si está protegido (marcado como sin conexión), lo saltamos y NO lo borramos
        if (isOfflineProtected) continue;

        // Si no está protegido, proceder con la purga LRU
        final fileSize = await file.length();
        await file.delete();
        totalSize -= fileSize;
      }
    }
  }

  Future<bool> isFileLocallyAvailable(String fileName) async {
    final cacheDir = await getCacheDirectory();
    final file = File('${cacheDir.path}/$fileName');
    return await file.exists();
  }

  Future<File> cacheFile(String fileName, List<int> bytes) async {
    await enforceLruLimit();
    final cacheDir = await getCacheDirectory();
    final file = File('${cacheDir.path}/$fileName');
    await file.writeAsBytes(bytes);
    return file;
  }
}
