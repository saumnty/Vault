import 'package:flutter/material.dart';

import '../../../data/models/folder_model.dart';
import '../../../data/models/vault_item_model.dart';

/// Elemento mostrable en la cuadrícula: carpeta o archivo.
sealed class BrowserEntry {
  const BrowserEntry();

  /// Clave única (carpetas y archivos pueden compartir id en teoría).
  String get key;
  String get name;
}

class FolderEntry extends BrowserEntry {
  const FolderEntry(this.folder);

  final FolderModel folder;

  @override
  String get key => 'd:${folder.id}';

  @override
  String get name => folder.name;
}

class FileEntry extends BrowserEntry {
  const FileEntry(this.item);

  final VaultItemModel item;

  @override
  String get key => 'f:${item.id}';

  @override
  String get name => item.name;

  /// Etiqueta de `Hero` compartida entre la celda y el visor.
  String get heroTag => heroTagFor(item.id);

  static String heroTagFor(String itemId) => 'vault-item-$itemId';
}

enum FileKind { image, video, audio, pdf, other }

/// Tipo de archivo. `VaultImportService` guarda a veces la extensión en lugar
/// del MIME, así que se mira también el nombre.
FileKind fileKindOf(VaultItemModel item) {
  final mime = item.mimeType.toLowerCase();
  if (mime.startsWith('image/')) return FileKind.image;
  if (mime.startsWith('video/')) return FileKind.video;
  if (mime.startsWith('audio/')) return FileKind.audio;
  if (mime == 'application/pdf') return FileKind.pdf;
  final dot = item.name.lastIndexOf('.');
  final ext = dot < 0 ? mime : item.name.substring(dot + 1).toLowerCase();
  const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'};
  const videos = {'mp4', 'mov', 'mkv', 'avi', 'webm', '3gp'};
  const audios = {'mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'};
  if (images.contains(ext)) return FileKind.image;
  if (videos.contains(ext)) return FileKind.video;
  if (audios.contains(ext)) return FileKind.audio;
  if (ext == 'pdf') return FileKind.pdf;
  return FileKind.other;
}

IconData iconForKind(FileKind kind) => switch (kind) {
  FileKind.image => Icons.image_outlined,
  FileKind.video => Icons.play_circle_outline,
  FileKind.audio => Icons.audiotrack_outlined,
  FileKind.pdf => Icons.picture_as_pdf_outlined,
  FileKind.other => Icons.insert_drive_file_outlined,
};

String labelForKind(FileKind kind) => switch (kind) {
  FileKind.image => 'Imagen',
  FileKind.video => 'Video',
  FileKind.audio => 'Audio',
  FileKind.pdf => 'PDF',
  FileKind.other => 'Archivo',
};
