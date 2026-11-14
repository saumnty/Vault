class FolderModel {
  final String id;
  final String name;
  final String? parentId;
  final String createdAt;

  FolderModel({
    required this.id,
    required this.name,
    this.parentId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'parentId': parentId,
      'createdAt': createdAt,
    };
  }

  factory FolderModel.fromMap(Map<String, dynamic> map) {
    return FolderModel(
      id: map['id'],
      name: map['name'],
      parentId: map['parentId'],
      createdAt: map['createdAt'],
    );
  }
}