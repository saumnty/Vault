import '../../core/services/app_paths.dart';
import 'sync_status.dart';

class VaultItemModel {
  final String id;
  final String name;
  final String? folderId;

  /// Ruta RELATIVA al directorio de la app, p. ej. `vault/<id>.vault`.
  final String encryptedPath;
  final int fileSize;
  final String mimeType;
  final String createdAt;

  /// El usuario pidió tenerlo siempre local. Ver también el flag heredado de
  /// carpetas: `VaultDataRepository.isEffectivelyOffline`.
  final bool isOffline;
  final bool isFavorite;

  /// Id del archivo en Drive (appDataFolder).
  final String? driveFileId;
  final SyncStatus syncStatus;

  /// Ruta RELATIVA de la miniatura cifrada, p. ej. `thumbs/<id>.thumb`.
  final String? thumbPath;

  /// Epoch ms del último acceso (LRU de caché).
  final int? lastAccessedAt;

  /// SHA-256 hex del contenido original (sin cifrar).
  final String? contentHash;

  /// Id del original en la galería del sistema.
  final String? sourceAssetId;

  /// Duración en ms (videos).
  final int? durationMs;

  const VaultItemModel({
    required this.id,
    required this.name,
    this.folderId,
    required this.encryptedPath,
    required this.fileSize,
    required this.mimeType,
    required this.createdAt,
    this.isOffline = false,
    this.isFavorite = false,
    this.driveFileId,
    this.syncStatus = SyncStatus.pendiente,
    this.thumbPath,
    this.lastAccessedAt,
    this.contentHash,
    this.sourceAssetId,
    this.durationMs,
  });

  /// Lanza [ArgumentError] si alguna ruta es absoluta.
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'folderId': folderId,
    'encryptedPath': AppPaths.validateRelative(encryptedPath),
    'fileSize': fileSize,
    'mimeType': mimeType,
    'createdAt': createdAt,
    'isOffline': isOffline ? 1 : 0,
    'isFavorite': isFavorite ? 1 : 0,
    'driveFileId': driveFileId,
    'syncStatus': syncStatus.dbValue,
    'thumbPath': thumbPath == null
        ? null
        : AppPaths.validateRelative(thumbPath!),
    'lastAccessedAt': lastAccessedAt,
    'contentHash': contentHash,
    'sourceAssetId': sourceAssetId,
    'durationMs': durationMs,
  };

  factory VaultItemModel.fromMap(Map<String, dynamic> map) => VaultItemModel(
    id: map['id'] as String,
    name: map['name'] as String,
    folderId: map['folderId'] as String?,
    encryptedPath: map['encryptedPath'] as String,
    fileSize: map['fileSize'] as int,
    mimeType: (map['mimeType'] as String?) ?? 'application/octet-stream',
    createdAt: map['createdAt'] as String,
    isOffline: (map['isOffline'] ?? 0) == 1,
    isFavorite: (map['isFavorite'] ?? 0) == 1,
    driveFileId: map['driveFileId'] as String?,
    syncStatus: SyncStatus.fromDb(map['syncStatus'] as String?),
    thumbPath: map['thumbPath'] as String?,
    lastAccessedAt: map['lastAccessedAt'] as int?,
    contentHash: map['contentHash'] as String?,
    sourceAssetId: map['sourceAssetId'] as String?,
    durationMs: map['durationMs'] as int?,
  );
}
