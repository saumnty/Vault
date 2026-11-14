class VaultItemModel {
  final String id;
  final String originalName;
  final String mimeType;
  final int sizeBytes;
  final String localPath;
  final String? cloudId;
  final String? folderId;
  final bool isSynced;
  final bool isFavorite;
  final bool isOffline; // <-- Nuevo: Indica si debe quedarse guardado localmente de forma permanente
  final String createdAt;

  VaultItemModel({
    required this.id,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.localPath,
    this.cloudId,
    this.folderId,
    required this.isSynced,
    required this.isFavorite,
    required this.isOffline,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'originalName': originalName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'localPath': localPath,
      'cloudId': cloudId,
      'folderId': folderId,
      'isSynced': isSynced ? 1 : 0,
      'isFavorite': isFavorite ? 1 : 0,
      'isOffline': isOffline ? 1 : 0, // Mapeo a entero para SQLCipher
      'createdAt': createdAt,
    };
  }

  factory VaultItemModel.fromMap(Map<String, dynamic> map) {
    return VaultItemModel(
      id: map['id'],
      originalName: map['originalName'],
      mimeType: map['mimeType'],
      sizeBytes: map['sizeBytes'],
      localPath: map['localPath'],
      cloudId: map['cloudId'],
      folderId: map['folderId'],
      isSynced: map['isSynced'] == 1,
      isFavorite: map['isFavorite'] == 1,
      isOffline: map['isOffline'] == 1,
      createdAt: map['createdAt'],
    );
  }
}