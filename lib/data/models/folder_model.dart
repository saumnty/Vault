class FolderModel {
  final String id;
  final String name;
  final String? parentId;
  final String createdAt;

  /// Marcada para uso sin conexión; el contenido la hereda
  /// (ver `VaultDataRepository.isEffectivelyOffline`).
  final bool isOffline;

  const FolderModel({
    required this.id,
    required this.name,
    this.parentId,
    required this.createdAt,
    this.isOffline = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'createdAt': createdAt,
    'isOffline': isOffline ? 1 : 0,
  };

  factory FolderModel.fromMap(Map<String, dynamic> map) => FolderModel(
    id: map['id'] as String,
    name: map['name'] as String,
    parentId: map['parentId'] as String?,
    createdAt: map['createdAt'] as String,
    isOffline: (map['isOffline'] ?? 0) == 1,
  );
}
