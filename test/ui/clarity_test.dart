// Claridad de la UI: nota de privacidad de la nube, aviso de originales,
// recomendación de 720p y mensaje final de la importación.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/gallery/gallery_asset_source.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/data/gallery/import_preferences.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/gallery/delete_originals_sheet.dart';
import 'package:vault/features/gallery/gallery_deps.dart';
import 'package:vault/features/gallery/import_options_sheet.dart';
import 'package:vault/features/gallery/import_progress_sheet.dart';
import 'package:vault/features/gallery/originals_pending_banner.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/shared/widgets/cloud_privacy_note.dart';

import '../support/fakes.dart';
import '../support/ui_helpers.dart';

class _NoSource implements GalleryAssetSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Servicio de importación falso: resultado fijo y conteo de pendientes.
class _FakeService implements GalleryImportService {
  _FakeService({this.pending = 0, this.result});

  int pending;
  final ImportBatchResult? result;
  int verifiedCalls = 0;

  @override
  final ValueNotifier<ImportBatchProgress> progress = ValueNotifier(
    const ImportBatchProgress(),
  );

  @override
  Future<ImportBatchResult> importAssets(
    List<GalleryAsset> assets,
    ImportOptions options, {
    ImportCancelToken? cancelToken,
  }) async => result!;

  @override
  Future<int> pendingOriginalsCount() async => pending;

  @override
  Future<List<VaultItemModel>> verifiedDeleteCandidates({
    void Function(int done, int total)? onProgress,
  }) async {
    verifiedCalls++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('CloudPrivacyNote', () {
    testWidgets('texto corto visible y detalle expandible', (tester) async {
      usePhoneSize(tester);
      await tester.pumpWidget(testApp(const Scaffold(body: CloudPrivacyNote())));
      expect(find.textContaining('cifrados a una carpeta oculta'), findsOneWidget);
      expect(find.textContaining('Google Fotos'), findsOneWidget);
      expect(find.textContaining('tu PIN o tu código de recuperación'),
          findsOneWidget);
      expect(find.textContaining('Administrar aplicaciones'), findsNothing);

      await tester.tap(find.text('Más información'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'drive.google.com > Configuración (el engranaje) > '
          'Administrar aplicaciones > Vault',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('verificación en dos pasos'), findsOneWidget);

      await tester.tap(find.text('Ocultar detalles'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Administrar aplicaciones'), findsNothing);
    });

    testWidgets('accesible: botón con estado expandido', (tester) async {
      final handle = tester.ensureSemantics();
      usePhoneSize(tester);
      await tester.pumpWidget(testApp(const Scaffold(body: CloudPrivacyNote())));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  group('Hoja de opciones de importación', () {
    const video = GalleryAsset(
      id: 'v',
      type: GalleryAssetType.video,
      duration: Duration(seconds: 80),
      sizeBytes: 100 * 1024 * 1024,
    );

    Future<void> open(WidgetTester tester, {List<GalleryAsset>? assets}) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SingleChildScrollView(
              child: ImportOptionsContent(
                assets: assets ?? [video],
                initialDeleteOriginals: false,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('720p recomendado con ahorro, sin cambiar el valor inicial', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Recomendado'), findsOneWidget);
      // 100 MB original - 80 s a 2,5 Mbps (≈23,84 MB) = ≈76,16 MB
      expect(find.text('Ahorras ≈ 76,16 MB'), findsOneWidget);
      // Sigue preseleccionado Original (un solo radio marcado).
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      final original = find.bySemanticsLabel(RegExp('^Calidad Original'));
      expect(original, findsOneWidget);
    });

    testWidgets('sin tamaño original conocido no inventa el ahorro', (
      tester,
    ) async {
      await open(
        tester,
        assets: const [
          GalleryAsset(
            id: 'v',
            type: GalleryAssetType.video,
            duration: Duration(seconds: 80),
          ),
        ],
      );
      expect(find.text('Recomendado'), findsOneWidget);
      expect(find.textContaining('Ahorras'), findsNothing);
    });

    testWidgets('solo fotos: sin calidades ni recomendación', (tester) async {
      await open(
        tester,
        assets: const [GalleryAsset(id: 'a', type: GalleryAssetType.image)],
      );
      expect(find.text('Recomendado'), findsNothing);
    });

    testWidgets('interruptor de borrar originales con el texto aclaratorio', (
      tester,
    ) async {
      await open(tester);
      expect(find.text(deleteOriginalsExplanation), findsOneWidget);
      expect(deleteOriginalsExplanation, contains('Apagado por defecto'));
      expect(deleteOriginalsExplanation, contains('verificada en la nube'));
      expect(deleteOriginalsExplanation, contains('confirmación'));
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
    });
  });

  group('Hoja final de importación', () {
    const asset = GalleryAsset(id: 'a', type: GalleryAssetType.image);
    final ok = ImportBatchResult(const [
      ImportItemResult(assetId: 'a', stage: ImportStage.done),
    ], cancelled: false);

    Future<void> run(WidgetTester tester, {required bool deleteEnabled}) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SingleChildScrollView(
              child: ImportProgressContent(
                service: _FakeService(result: ok),
                assets: const [asset],
                options: const ImportOptions(),
                deleteOriginalsEnabled: deleteEnabled,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('borrado apagado: los originales siguen; se borran en Ajustes', (
      tester,
    ) async {
      await run(tester, deleteEnabled: false);
      expect(find.text('Importación completa'), findsOneWidget);
      expect(
        find.text(
          'Los originales siguen en tu galería; cuando estén en la nube '
          'podrás borrarlos desde Ajustes.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('borrado activado: texto adaptado, siempre con confirmación', (
      tester,
    ) async {
      await run(tester, deleteEnabled: true);
      expect(
        find.textContaining('Los originales siguen en tu galería. Cuando su '
            'copia esté verificada en la nube'),
        findsOneWidget,
      );
      expect(find.textContaining('desde Ajustes'), findsNothing);
    });
  });

  group('Aviso de originales pendientes', () {
    testWidgets('el widget muestra la cuenta y llama a Borrar ahora', (
      tester,
    ) async {
      usePhoneSize(tester);
      var taps = 0;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: OriginalsPendingBanner(count: 3, onDelete: () => taps++),
          ),
        ),
      );
      expect(find.textContaining('3 originales ya están en la nube'),
          findsOneWidget);
      await tester.tap(find.text('Borrar ahora'));
      expect(taps, 1);
    });

    Future<_FakeService> openHome(WidgetTester tester, int pending) async {
      usePhoneSize(tester);
      final service = _FakeService(pending: pending);
      final base = fakeServices(FakeVaultRepository());
      final services = VaultServices(
        repository: base.repository,
        importFile: base.importFile,
        syncRunner: base.syncRunner,
        thumbnailLoader: base.thumbnailLoader,
        fileCleaner: base.fileCleaner,
        offlineToggler: base.offlineToggler,
        gallery: GalleryDeps(
          source: _NoSource(),
          service: service,
          preferences: GalleryImportPreferences(InMemorySecureStore()),
        ),
      );
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(currentFolderName: 'Mi Bóveda', services: services),
        ),
      );
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('con pendientes: aviso en la cuadrícula y flujo de borrado', (
      tester,
    ) async {
      final service = await openHome(tester, 2);
      expect(find.textContaining('2 originales ya están en la nube'),
          findsOneWidget);
      await tester.tap(find.text('Borrar ahora'));
      await tester.pumpAndSettle();
      // Reutiliza la hoja existente (consulta y lista verificada).
      expect(service.verifiedCalls, 1);
      expect(find.text('No hay originales para borrar'), findsOneWidget);
    });

    testWidgets('sin pendientes (o borrado apagado): sin aviso', (tester) async {
      await openHome(tester, 0);
      expect(find.text('Borrar ahora'), findsNothing);
    });
  });
}
