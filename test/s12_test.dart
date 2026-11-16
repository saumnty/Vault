// Regresión S-12: sin logs en release y sin texto de excepciones en la UI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/logging/vault_log.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/features/gallery/import_progress_sheet.dart';

class _ThrowingService implements GalleryImportService {
  @override
  final ValueNotifier<ImportBatchProgress> progress = ValueNotifier(
    const ImportBatchProgress(),
  );

  @override
  Future<ImportBatchResult> importAssets(
    List<GalleryAsset> assets,
    ImportOptions options, {
    ImportCancelToken? cancelToken,
  }) async => throw FileSystemLikeException('/data/user/0/secreto/foto_X.jpg');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FileSystemLikeException implements Exception {
  FileSystemLikeException(this.path);
  final String path;
  @override
  String toString() => 'FileSystemLikeException: $path';
}

void main() {
  tearDown(VaultLog.reset);

  test('en release (isDebug=false) el logger no emite nada', () {
    final out = <String>[];
    VaultLog.sink = out.add;
    VaultLog.isDebug = () => false;
    VaultLog.d('hola');
    VaultLog.e('falló', Exception('/ruta/secreta'));
    expect(out, isEmpty);
  });

  test('en debug solo registra el runtimeType del error', () {
    final out = <String>[];
    VaultLog.sink = out.add;
    VaultLog.isDebug = () => true;
    VaultLog.e('falló', const FormatException('/ruta/secreta'));
    expect(out.single, 'falló (FormatException)');
    expect(out.single, isNot(contains('secreta')));
  });

  testWidgets('la hoja de importación no muestra el texto de la excepción', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportProgressContent(
              service: _ThrowingService(),
              assets: const [
                GalleryAsset(id: 'a', type: GalleryAssetType.image),
              ],
              options: const ImportOptions(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No se pudo importar'), findsOneWidget);
    expect(find.textContaining('secreto'), findsNothing);
    expect(find.textContaining('FileSystemLike'), findsNothing);
  });
}
