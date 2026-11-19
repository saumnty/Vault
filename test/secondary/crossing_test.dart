// Fase 8, paso 5 (DISENO_SENUELO §4.1, §11.2-7 y 8): toda operación larga
// que cruza "bloquear → abrir la otra bóveda" no toca la otra bóveda ni cifra
// nada con sus llaves. Las operaciones corren en las DOS direcciones.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/cache_manager.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/gallery/gallery_import_service.dart';
import 'package:vault/data/gallery/thumbnail_regeneration_service.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/data/rotation/item_reencryptor.dart';
import 'package:vault/data/services/vault_import_service.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';
import 'package:vault/features/vault/services/trash_service.dart';
import 'package:vault/features/vault/viewer/media_exporter.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';

import 'support/crossing_harness.dart';

class _NoCompressor implements VideoCompressor {
  @override
  Future<CompressedVideo?> compress(
    File source,
    VideoQualityOption quality, {
    void Function(double)? onProgress,
  }) async => null;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> cleanup() async {}
}

void main() {
  for (final slot in VaultSlot.values) {
    group('desde la ${slot.name}', () {
      test('importación de la galería', () async {
        final runs = await runCrossing(
          slot: slot,
          op: (e) async {
            final scratch = Directory(p.join(e.base.path, 'scratch'))
              ..createSync(recursive: true);
            final source = GatedSource(e.gate, scratch);
            final svc = GalleryImportService(
              source: source,
              compressor: _NoCompressor(),
              repository: e.repo(slot),
              filesKey: () =>
                  e.session.isUnlockedAs(slot) ? e.session.filesKey : null,
              thumbsKey: () => e.session.isUnlockedAs(slot)
                  ? e.session.keysOrNull?.thumbs
                  : null,
              tempDirProvider: () => e.paths(slot).importTmpDir,
              paths: e.paths(slot),
              sessionTicket: e.ticketFor(slot),
              videoThumbnailer: NoVideoThumbs(),
              isIOS: false,
            );
            return svc.importAssets([
              source.asset('a1'),
              source.asset('a2'),
            ], const ImportOptions());
          },
        );
        expect(runs.length, greaterThan(3));
      });

      test('importación de un archivo (selector propio)', () async {
        final runs = await runCrossing(
          slot: slot,
          op: (e) => VaultImportService(
            picker: GatedPicker(e.gate),
            filesKey: () =>
                e.session.isUnlockedAs(slot) ? e.session.filesKey : null,
            keyGen: () => 1,
            repository: e.repo(slot),
            paths: e.paths(slot),
            sessionTicket: e.ticketFor(slot),
          ).importAndEncryptFile(targetFolderId: null),
        );
        expect(runs.length, greaterThan(2));
      });

      test('regeneración de miniaturas', () async {
        await runCrossing(
          slot: slot,
          op: (e) {
            final scratch = Directory(p.join(e.base.path, 'scratch'))
              ..createSync(recursive: true);
            // Dos candidatos: el segundo lee sus llaves DESPUÉS del cruce
            // (A1-2 de la revisión; una mutación sin llaves ligadas lo cifra
            // con las de la otra bóveda y el arnés lo detecta).
            final t = e.paths(slot).resolve(e.seeded[slot]![1].thumbPath!);
            if (t.existsSync()) t.deleteSync();
            return ThumbnailRegenerationService(
              repository: e.repo(slot),
              source: GatedSource(e.gate, scratch),
              videoThumbnailer: NoVideoThumbs(),
              filesKey: (g) => e.session.filesKeyFor(g, slot),
              thumbsKey: (g) => e.session.thumbsKeyFor(g, slot),
              tempDirProvider: () => e.paths(slot).importTmpDir,
              paths: e.paths(slot),
              sessionTicket: e.ticketFor(slot),
            ).run(manual: true);
          },
        );
      });

      test('Papelera: eliminar definitivamente', () async {
        await runCrossing(
          slot: slot,
          op: (e) => TrashService(
            repository: e.trashRepo(slot),
            fileCleaner: (ids) async {
              await e.gate.hit('cleaner');
              for (final id in ids) {
                for (final f in [
                  e.paths(slot).resolve('vault/$id.vault'),
                  e.paths(slot).resolve('thumbs/$id.thumb'),
                ]) {
                  if (f.existsSync()) f.deleteSync();
                }
              }
            },
            sessionTicket: e.ticketFor(slot),
          ).emptyAll(),
        );
      });

      test('caché LRU (purga total)', () async {
        await runCrossing(
          slot: slot,
          op: (e) => CacheManager(
            repository: e.repo(slot),
            preferences: CachePreferences(e.store),
            resolvePath: e.paths(slot).resolve,
            sessionTicket: e.ticketFor(slot),
          ).enforce(maxBytes: 0),
        );
      });

      test('descarga de un .vault que solo está en la nube', () async {
        await runCrossing(
          slot: slot,
          op: (e) => VaultFileFetcher(
            cloud: e.cloud,
            items: e.repo(slot),
            resolvePath: e.paths(slot).resolve,
            sessionTicket: e.ticketFor(slot),
          ).ensureLocal(e.seeded[slot]![2]),
        );
      });

      test('Guardar en Fotos: tras el cruce no sale nada', () async {
        await runCrossing(
          slot: slot,
          op: (e) async {
            final saver = GatedSaver(e.gate);
            final fetcher = VaultFileFetcher(
              cloud: e.cloud,
              items: e.repo(slot),
              resolvePath: e.paths(slot).resolve,
              sessionTicket: e.ticketFor(slot),
            );
            final out = await VaultMediaExporter(
              opener: VaultMediaOpener(
                fetcher: fetcher,
                filesKey: (g) => e.session.filesKeyFor(g, slot),
                temp: PlainTempManager(
                  dirProvider: () => e.paths(slot).tmpPlainDir,
                ),
              ),
              saver: saver,
              sessionTicket: e.ticketFor(slot),
            ).export(e.seeded[slot]![1]);
            // Con la sesión cambiada nunca se entrega nada a Fotos.
            if (!e.session.isUnlockedAs(slot)) {
              expect(saver.saved, isEmpty);
              expect(out, isNot(ExportOutcome.saved));
            }
            // Ningún temporal en claro queda en disco.
            final tmp = e.paths(slot).tmpPlainDir;
            if (tmp.existsSync()) expect(tmp.listSync(), isEmpty);
            return out;
          },
        );
      });
    });
  }

  test('al bloquear se cancelan el lote de importación y la regeneración '
      '(sin depender del ticket)', () async {
    final e = await CrossEnv.create();
    addTearDown(e.dispose);
    await e.open(VaultSlot.primary);
    final scratch = Directory(p.join(e.base.path, 'scratch'))
      ..createSync(recursive: true);
    final source = GatedSource(e.gate, scratch);
    final keys = e.session.keys;
    final svc = GalleryImportService(
      source: source,
      compressor: _NoCompressor(),
      repository: e.rawRepo(VaultSlot.primary),
      filesKey: () => keys.files,
      thumbsKey: () => keys.thumbs,
      tempDirProvider: () => e.paths(VaultSlot.primary).importTmpDir,
      videoThumbnailer: NoVideoThumbs(),
      isIOS: false,
    );
    final regen = ThumbnailRegenerationService(
      repository: e.rawRepo(VaultSlot.primary),
      source: source,
      videoThumbnailer: NoVideoThumbs(),
      filesKey: (_) => keys.files,
      thumbsKey: (_) => keys.thumbs,
      tempDirProvider: () => e.paths(VaultSlot.primary).importTmpDir,
    );
    e.session.addOnClear(svc.cancelRunning);
    e.session.addOnClear(regen.cancel);
    e.gate.pauseAt = 0; // primer punto: isLocallyAvailable del 1.er asset
    final running = svc.importAssets([
      source.asset('a1'),
      source.asset('a2'),
    ], const ImportOptions());
    await e.gate.reached.future;
    e.session.clear();
    e.gate.release.complete();
    final r = await running;
    expect(r.cancelled, isTrue);
    expect(r.succeeded, 0);
    expect(svc.progress.value.running, isFalse);
    expect(svc.isRunning, isFalse);
    expect(regen.isRunning, isFalse);
  });

  test('re-cifrado de un item (rotación, solo principal)', () async {
    await runCrossing(
      slot: VaultSlot.primary,
      op: (e) async {
        final to = await KeyHierarchy.fromDek(List.generate(32, (i) => i * 3));
        final from = await KeyHierarchy.fromDek(
          List.generate(32, (i) => i + 11),
        );
        return ItemReencryptor(
          items: e.repo(VaultSlot.primary),
          cloud: e.cloud,
          workDir: () => Directory(p.join(e.base.path, 'rot')),
          resolvePath: e.paths(VaultSlot.primary).resolve,
        ).reencrypt(
          e.seeded[VaultSlot.primary]![1],
          fromGen: 1,
          from: from,
          toGen: 2,
          to: to,
          ticket: e.ticketFor(VaultSlot.primary)(),
        );
      },
      // El re-cifrado deja `.k2` con la llave NUEVA (otra DEK): solo se
      // exige que la secundaria no cambie (lo hace el arnés).
      skipOwnKeysCheck: true,
    );
  });
}
