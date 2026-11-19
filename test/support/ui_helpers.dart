import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/theme/app_theme.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/folder_model.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';
import 'package:vault/data/sync/storage_service.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/features/vault/viewer/folder_album_export.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';

/// Envuelve [child] con el tema real de la app.
Widget testApp(Widget child, {NavigatorObserver? observer}) => MaterialApp(
  theme: AppTheme.dark,
  debugShowCheckedModeBanner: false,
  navigatorObservers: [?observer],
  home: child,
);

/// Pantalla de teléfono (390x844 lógicos).
void usePhoneSize(WidgetTester tester, {double dpr = 2}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
  addTearDown(tester.view.reset);
}

/// Carga Roboto + MaterialIcons del SDK de Flutter para que las capturas
/// muestren texto e íconos reales (si no, salen bloques "Ahem").
Future<bool> loadGoldenFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter-sdk\flutter';
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return false;

  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(await File('${dir.path}/$name').readAsBytes());

  final roboto = FontLoader('Roboto')
    ..addFont(bytes('roboto-regular.ttf'))
    ..addFont(bytes('roboto-medium.ttf'))
    ..addFont(bytes('roboto-bold.ttf'));
  await roboto.load();
  // 'monospace' no existe en el host de pruebas: se sustituye por Roboto para
  // que el código de recuperación sea legible (en el dispositivo es monoespaciada).
  final mono = FontLoader('monospace')..addFont(bytes('roboto-regular.ttf'));
  await mono.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('materialicons-regular.otf'));
  await icons.load();
  return true;
}

// ------------------------------------------------------------------ datos

VaultItemModel fakeItem(
  String id, {
  String? folderId,
  String? name,
  String mime = 'image/jpeg',
  int size = 2 * 1024 * 1024,
  SyncStatus status = SyncStatus.enNube,
  bool withThumb = true,
}) => VaultItemModel(
  keyGen: 1,
  id: id,
  name: name ?? 'IMG_$id.jpg',
  folderId: folderId,
  encryptedPath: 'vault/$id.vault',
  fileSize: size,
  mimeType: mime,
  createdAt: '2026-03-14T10:00:00',
  syncStatus: status,
  thumbPath: withThumb ? 'thumbs/$id.thumb' : null,
);

FolderModel fakeFolder(String id, String name, {String? parentId}) =>
    FolderModel(
      id: id,
      name: name,
      parentId: parentId,
      createdAt: '2026-02-01T09:00:00',
    );

/// Repositorio en memoria (sin SQLCipher ni SQLite).
class FakeVaultRepository extends Fake implements VaultDataRepository {
  FakeVaultRepository({
    List<FolderModel> folders = const [],
    List<VaultItemModel> items = const [],
  }) : folders = List.of(folders),
       items = List.of(items);

  final List<FolderModel> folders;
  final List<VaultItemModel> items;

  @override
  Future<List<FolderModel>> getFoldersByParent(String? parentId) async =>
      folders.where((f) => f.parentId == parentId).toList();

  @override
  Future<List<VaultItemModel>> getItemsByFolder(String? folderId) async =>
      items.where((i) => i.folderId == folderId).toList();

  @override
  Future<FolderModel?> getFolder(String id) async =>
      folders.where((f) => f.id == id).firstOrNull;

  @override
  Future<List<FolderModel>> getBreadcrumbs(String folderId) async {
    final chain = <FolderModel>[];
    var current = await getFolder(folderId);
    while (current != null) {
      chain.insert(0, current);
      current = current.parentId == null
          ? null
          : await getFolder(current.parentId!);
    }
    return chain;
  }

  @override
  Future<void> createFolder(FolderModel folder) async => folders.add(folder);

  @override
  Future<void> deleteItem(String id) async =>
      items.removeWhere((i) => i.id == id);

  @override
  Future<List<String>> deleteFolderRecursive(String folderId) async {
    folders.removeWhere((f) => f.id == folderId);
    return const [];
  }

  @override
  Future<void> moveItem(String itemId, String? folderId) async {
    final i = items.indexWhere((e) => e.id == itemId);
    final old = items[i];
    items[i] = VaultItemModel(
      keyGen: 1,
      id: old.id,
      name: old.name,
      folderId: folderId,
      encryptedPath: old.encryptedPath,
      fileSize: old.fileSize,
      mimeType: old.mimeType,
      createdAt: old.createdAt,
      syncStatus: old.syncStatus,
      thumbPath: old.thumbPath,
    );
  }

  @override
  Future<VaultItemModel?> getItem(String id) async =>
      items.where((i) => i.id == id).firstOrNull;

  @override
  Future<List<VaultItemModel>> getItemsInFolderTree(String folderId) async {
    final ids = <String>{folderId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in folders) {
        if (f.parentId != null && ids.contains(f.parentId) && ids.add(f.id)) {
          grew = true;
        }
      }
    }
    return items.where((i) => ids.contains(i.folderId)).toList();
  }

  @override
  Future<void> setFolderOffline(String id, bool isOffline) async {}
}

/// Abre medios con bytes/orígenes prefabricados (visor sin cifrado real).
class FakeMediaOpener implements MediaOpener {
  FakeMediaOpener({this.images = const {}, this.videoFactory});

  /// Bytes (PNG) por id de item. Si falta el id, `loadImage` falla con
  /// [imageError].
  final Map<String, Uint8List> images;
  Object imageError = const CloudNoNetworkException();
  VideoSource Function(VaultItemModel item)? videoFactory;
  final List<String> loaded = [];
  int failuresBeforeSuccess = 0;

  @override
  Future<Uint8List> loadImage(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  }) async {
    loaded.add(item.id);
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw imageError;
    }
    final b = images[item.id];
    if (b == null) throw imageError;
    return b;
  }

  @override
  VideoSource videoSource(VaultItemModel item) => videoFactory!(item);
}

/// Registro de llamadas de los servicios falsos.
class ServiceCalls {
  int syncs = 0;
  int imports = 0;
  final List<Iterable<String>> cleaned = [];
  final List<String> offline = [];
}

VaultServices fakeServices(
  VaultDataRepository repo, {
  ServiceCalls? calls,
  ThumbnailLoader? thumbnails,
  MediaOpener? mediaOpener,
  SyncService? sync,
  StorageService? storage,
  TagRepository? tags,
  KeyRotationService? rotation,
  FolderAlbumService? folderAlbums,
}) {
  final c = calls ?? ServiceCalls();
  return VaultServices(
    repository: repo,
    importFile: ({required folderId, required deleteOriginal}) async {
      c.imports++;
      return true;
    },
    syncRunner: () async => c.syncs++,
    thumbnailLoader: thumbnails ?? (item) async => null,
    mediaOpener: mediaOpener ?? const UnavailableMediaOpener(),
    fileCleaner: (ids) async => c.cleaned.add(ids.toList()),
    offlineToggler: (id, value) async {
      c.offline.add(id);
      return true;
    },
    sync: sync,
    storage: storage,
    tags: tags,
    rotation: rotation,
    folderAlbums: folderAlbums,
  );
}

/// PNG sintético (degradado + círculo) para miniaturas de prueba.
Future<Uint8List> makeThumbPng(Color a, Color b, {int size = 200}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [a, b]),
  );
  canvas.drawCircle(
    Offset(size * 0.65, size * 0.35),
    size * 0.14,
    Paint()..color = const Color(0x66FFFFFF),
  );
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
