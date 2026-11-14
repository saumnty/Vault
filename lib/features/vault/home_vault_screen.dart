import 'dart:io';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../data/repositories/vault_database.dart';
import '../../data/models/folder_model.dart';
import '../../data/services/vault_import_service.dart';
import '../../data/services/google_drive_service.dart';

class HomeVaultScreen extends StatefulWidget {
  final String? currentFolderId;
  final String currentFolderName;

  const HomeVaultScreen({
    super.key,
    this.currentFolderId,
    required this.currentFolderName,
  });

  @override
  State<HomeVaultScreen> createState() => _HomeVaultScreenState();
}

class _HomeVaultScreenState extends State<HomeVaultScreen> {
  final VaultDatabase _vaultDatabase = VaultDatabase();
  final VaultImportService _importService = VaultImportService();
  Database? _db;
  
  List<FolderModel> _folders = [];
  List<VaultItemModel> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initAndLoadData();
  }

  Future<void> _initAndLoadData() async {
    _db = await _vaultDatabase.database;
    await _loadData();
  }

  Future<void> _loadData() async {
    if (_db == null) return;
    
    setState(() => _isLoading = true);
    final folders = await _vaultDatabase.getFoldersByParent(_db!, widget.currentFolderId);
    final items = await _vaultDatabase.getItemsByFolder(_db!, widget.currentFolderId);
    
    setState(() {
      _folders = folders;
      _items = items;
      _isLoading = false;
    });
  }

  Future<void> _createNewFolder(String name) async {
    if (_db == null || name.trim().isEmpty) return;

    final newFolder = FolderModel(
      id: const Uuid().v4(),
      name: name.trim(),
      parentId: widget.currentFolderId,
      createdAt: DateTime.now().toIso8601String(),
    );

    await _vaultDatabase.createFolder(_db!, newFolder);
    await _loadData(); 
  }

  final GoogleDriveService _driveService = GoogleDriveService();

  Future<void> _syncToGoogleDrive() async {
    // 1. Intentar iniciar sesión (si no está autenticado)
    bool signedIn = await _driveService.signIn();
    if (!signedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo iniciar sesión en Google Drive.'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    // 2. Subir cada archivo cifrado local al Drive
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sincronizando archivos con Google Drive...'), backgroundColor: Color(0xFF7C3AED)),
      );
    }

    int uploadedCount = 0;
    for (var item in _items) {
      final file = File(item.encryptedPath);
      if (await file.exists()) {
        // Subimos el archivo usando su ID único con extensión .vault
        bool success = await _driveService.uploadEncryptedFile(file, '${item.id}.vault');
        if (success) uploadedCount++;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('¡Sincronización completa! $uploadedCount archivos respaldados en la nube.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// Muestra un diálogo preguntando si se desea eliminar el archivo original de la galería
  void _showImportOptionsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF18181C),
        title: const Text('Importar al Vault', style: TextStyle(color: Colors.white)),
        content: const Text(
          '¿Deseas eliminar el archivo original de la galería pública de tu dispositivo después de cifrarlo?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _importFile(deleteOriginal: false);
            },
            child: const Text('Conservar original', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
            onPressed: () {
              Navigator.pop(context);
              _importFile(deleteOriginal: true);
            },
            child: const Text('Cifrar y Eliminar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _importFile({required bool deleteOriginal}) async {
    try {
      bool success = await _importService.importAndEncryptFile(
        targetFolderId: widget.currentFolderId,
        deleteOriginal: deleteOriginal,
      );
      
      if (success) {
        await _loadData(); 
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                deleteOriginal 
                  ? '¡Archivo cifrado y original eliminado con éxito!' 
                  : '¡Archivo importado y cifrado exitosamente!',
              ),
              backgroundColor: const Color(0xFF7C3AED),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Importación cancelada o sesión sin llave.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Excepción al invocar selector: $e');
    }
  }

  void _showCreateFolderDialog() {
    final TextEditingController nameController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF18181C),
        title: const Text('Nueva Carpeta', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Nombre de la carpeta',
            hintStyle: TextStyle(color: Colors.white54),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF7C3AED))),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _createNewFolder(nameController.text);
            },
            child: const Text('Crear', style: TextStyle(color: Color(0xFF7C3AED))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0B0E),
        elevation: 0,
        title: Text(
          widget.currentFolderName,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_upload, color: Colors.blueAccent),
            onPressed: _syncToGoogleDrive,
            tooltip: 'Sincronizar con Google Drive',
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder, color: Color(0xFF7C3AED)),
            onPressed: _showCreateFolderDialog,
            tooltip: 'Crear carpeta',
          ),
          IconButton(
            icon: const Icon(Icons.upload_file, color: Color(0xFF7C3AED)),
            onPressed: _showImportOptionsDialog,
            tooltip: 'Importar archivo',
          ),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Color(0xFF7C3AED)))
        : (_folders.isEmpty && _items.isEmpty)
            ? const Center(
                child: Text(
                  'Esta carpeta está vacía',
                  style: TextStyle(color: Colors.white54, fontSize: 16),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ..._folders.map((folder) => ListTile(
                    leading: const Icon(Icons.folder, color: Color(0xFF7C3AED), size: 40),
                    title: Text(folder.name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      folder.createdAt.substring(0, 10), 
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => HomeVaultScreen(
                            currentFolderId: folder.id,
                            currentFolderName: folder.name,
                          ),
                        ),
                      );
                    },
                  )),
                  
                  ..._items.map((item) => ListTile(
                    leading: const Icon(Icons.lock_outline, color: Colors.blueAccent, size: 36),
                    title: Text(item.name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      '${(item.fileSize / 1024 / 1024).toStringAsFixed(2)} MB • Cifrado seguro',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Archivo seleccionado: ${item.name}')),
                      );
                    },
                  )),
                ],
              ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF7C3AED),
        onPressed: _showImportOptionsDialog,
        tooltip: 'Importar Archivo',
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}