import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/theme/app_spacing.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/features/gallery/gallery_picker_screen.dart';
import 'package:vault/features/gallery/import_options_sheet.dart';

import '../support/ui_helpers.dart';

class _Source implements GalleryAssetSource {
  _Source({this.permission = GalleryPermission.granted});
  final GalleryPermission permission;
  int settingsOpened = 0;
  final assets = [
    const GalleryAsset(id: 'a', type: GalleryAssetType.image),
    const GalleryAsset(
      id: 'b',
      type: GalleryAssetType.video,
      duration: Duration(seconds: 75),
    ),
    const GalleryAsset(id: 'c', type: GalleryAssetType.image),
  ];

  @override
  Future<GalleryPermission> requestPermission() async => permission;
  @override
  Future<void> openSettings() async => settingsOpened++;
  @override
  Future<int> assetCount() async => assets.length;
  @override
  Future<List<GalleryAsset>> listAssets({
    required int page,
    required int size,
  }) async => page == 0 ? assets : const [];
  @override
  Future<bool> isLocallyAvailable(String id) async => true;
  @override
  Future<OriginFile?> originFile(
    String id, {
    bool allowNetwork = false,
    void Function(double)? onProgress,
  }) async => null;
  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async => null;
  @override
  Future<List<String>> deleteAssets(List<String> ids) async => const [];
  @override
  Future<void> clearPlainCaches() async {}
}

void main() {
  testWidgets('selector: multi-selección y devuelve en orden', (tester) async {
    usePhoneSize(tester);
    List<GalleryAsset>? result;
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<List<GalleryAsset>>(
                MaterialPageRoute(
                  builder: (_) => GalleryPickerScreen(source: _Source()),
                ),
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Foto 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Video de 75 segundos 2'), findsOneWidget);
    expect(find.text('1:15'), findsOneWidget);
    expect(find.textContaining('Importar'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Video de 75 segundos 2'));
    await tester.tap(find.bySemanticsLabel('Foto 1'));
    await tester.pumpAndSettle();
    expect(find.text('2 seleccionados'), findsOneWidget);
    expect(find.bySemanticsLabel('Foto 1, seleccionado'), findsOneWidget);

    await tester.tap(find.text('Importar 2'));
    await tester.pumpAndSettle();
    expect(result!.map((a) => a.id), ['b', 'a']);
  });

  testWidgets('selector: permiso denegado muestra ajustes', (tester) async {
    usePhoneSize(tester);
    final src = _Source(permission: GalleryPermission.denied);
    await tester.pumpWidget(testApp(GalleryPickerScreen(source: src)));
    await tester.pumpAndSettle();
    expect(find.text('Sin acceso a la galería'), findsOneWidget);
    await tester.tap(find.text('Abrir ajustes'));
    expect(src.settingsOpened, 1);
  });

  testWidgets('opciones: calidad con tamaños, toggle apagado por defecto', (
    tester,
  ) async {
    usePhoneSize(tester);
    ImportChoices? choices;
    final assets = [
      const GalleryAsset(
        id: 'v',
        type: GalleryAssetType.video,
        duration: Duration(seconds: 80),
        sizeBytes: 100 * 1024 * 1024,
      ),
    ];
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => choices = await showImportOptionsSheet(
              context,
              assets: assets,
              deleteOriginalsWhenInCloud: false,
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.text('Original'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.textContaining('Antes 100,00 MB'), findsNWidgets(2));
    expect(find.textContaining('≈ 47,68 MB'), findsOneWidget); // 80 s a 5 Mbps
    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isFalse);
    // Áreas táctiles >= 44.
    expect(
      tester.getSize(find.bySemanticsLabel(RegExp('Calidad 720p'))).height,
      greaterThanOrEqualTo(AppSizes.minTouch),
    );

    await tester.tap(find.text('720p'));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cifrar e importar'));
    await tester.pumpAndSettle();
    expect(choices!.videoQuality, VideoQualityOption.p720);
    expect(choices!.deleteOriginalsWhenInCloud, isTrue);
  });
}
