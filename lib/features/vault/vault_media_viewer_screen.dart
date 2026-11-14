import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cryptography/cryptography.dart';
import 'services/vault_viewer_service.dart';

class VaultMediaViewerScreen extends StatefulWidget {
  final String cloudId;
  final String fileName;
  final String mimeType;
  final SecretKey secretKey;

  const VaultMediaViewerScreen({
    super.key,
    required this.cloudId,
    required this.fileName,
    required this.mimeType,
    required this.secretKey,
  });

  @override
  State<VaultMediaViewerScreen> createState() => _VaultMediaViewerScreenState();
}

class _VaultMediaViewerScreenState extends State<VaultMediaViewerScreen> {
  final VaultViewerService _viewerService = VaultViewerService();
  bool _isLoading = true;
  File? _plainFile;

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    setState(() => _isLoading = true);

    final file = await _viewerService.getPlainFileForViewing(
      cloudId: widget.cloudId,
      fileName: widget.fileName,
      secretKey: widget.secretKey,
    );

    if (mounted) {
      setState(() {
        _plainFile = file;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Fondo negro absoluto para multimedia
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.fileName,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator(color: Color(0xFF7C3AED))
            : _plainFile == null
                ? const Text(
                    'No se pudo cargar el archivo desde la nube.',
                    style: TextStyle(color: Colors.white70),
                  )
                : _buildMediaContent(),
      ),
    );
  }

  Widget _buildMediaContent() {
    if (widget.mimeType.startsWith('image/')) {
      // Visualizador de Imagen
      return InteractiveViewer(
        child: Image.file(_plainFile!),
      );
    } else if (widget.mimeType.startsWith('video/')) {
      // Reproductor de Video (aquí integrarás video_player o chewie más adelante)
      return const Center(
        child: Text(
          'Reproductor de Video Bajo Demanda (Listo para integrar video_player)',
          style: TextStyle(color: Colors.white54),
          textAlign: TextAlign.center,
        ),
      );
    } else {
      return const Center(
        child: Text(
          'Vista previa no disponible para este tipo de archivo.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
  }
}