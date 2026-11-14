import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart';
import '../models/folder_model.dart';

class VaultItemModel {
  final String id;
  final String name;
  final String? folderId;
  final String encryptedPath;
  final int fileSize;
  final String mimeType;
  final String createdAt;
  final int isOffline;

  VaultItemModel({
    required this.id,
    required this.name,
    this.folderId,
    required this.encryptedPath,
    required this.fileSize,
    required this.mimeType,
    required this.createdAt,
    this.isOffline = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'folderId': folderId,
      'encryptedPath': encryptedPath,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'createdAt': createdAt,
      'isOffline': isOffline,
    };
  }

  factory VaultItemModel.fromMap(Map<String, dynamic> map) {
    return VaultItemModel(
      id: map['id'],
      name: map['name'],
      folderId: map['folderId'],
      encryptedPath: map['encryptedPath'],
      fileSize: map['fileSize'],
      mimeType: map['mimeType'],
      createdAt: map['createdAt'],
      isOffline: map['isOffline'] ?? 0,
    );
  }
}

class VaultDatabase {
  static final VaultDatabase _instance = VaultDatabase._internal();
  static Database? _database;

  factory VaultDatabase() => _instance;
  VaultDatabase._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('vault_secure.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      password: 'temporal_dev_password',
      version: 2, // Subimos versión para aplicar migración de la tabla items
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createVaultItemsTable(db);
        }
      },
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parentId TEXT,
        createdAt TEXT NOT NULL
      )
    ''');
    
    await _createVaultItemsTable(db);
  }

  Future _createVaultItemsTable(Database db) async {
    await db.execute('''
      CREATE TABLE vault_items (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        folderId TEXT,
        encryptedPath TEXT NOT NULL,
        fileSize INTEGER NOT NULL,
        mimeType TEXT,
        createdAt TEXT NOT NULL,
        isOffline INTEGER DEFAULT 0
      )
    ''');
  }

  // Métodos de Carpetas
  Future<void> createFolder(Database db, FolderModel folder) async {
    await db.insert('folders', folder.toMap());
  }

  Future<List<FolderModel>> getFoldersByParent(Database db, String? parentId) async {
    final result = await db.query(
      'folders',
      where: parentId == null ? 'parentId IS NULL' : 'parentId = ?',
      whereArgs: parentId == null ? [] : [parentId],
      orderBy: 'createdAt DESC',
    );
    return result.map((json) => FolderModel.fromMap(json)).toList();
  }

  // Métodos de Archivos (Vault Items)
  Future<void> insertItem(Database db, VaultItemModel item) async {
    await db.insert('vault_items', item.toMap());
  }

  Future<List<VaultItemModel>> getItemsByFolder(Database db, String? folderId) async {
    final result = await db.query(
      'vault_items',
      where: folderId == null ? 'folderId IS NULL' : 'folderId = ?',
      whereArgs: folderId == null ? [] : [folderId],
      orderBy: 'createdAt DESC',
    );
    return result.map((json) => VaultItemModel.fromMap(json)).toList();
  }
}