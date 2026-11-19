// v2.2: «Guardar en Fotos como álbum» (carpeta -> álbum, por lotes).
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/session/session_ticket.dart';
import 'package:vault/core/session/vault_slot.dart';
import 'package:vault/data/gallery/photo_saver.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/viewer/folder_album_export.dart';
import 'package:vault/features/vault/viewer/media_exporter.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';
import 'package:vault/features/vault/widgets/album_export_dialog.dart';
import 'package:vault/features/vault/widgets/folder_tile.dart';

import 'support/f6_env.dart';
import 'support/ui_helpers.dart';

/// Exportador falso con resultados por id y puertas para pausar a mitad.
class FakeAlbumExporter implements AlbumMediaExporter {
  bool allow = true;
  int permissionAsks = 0;
  int settingsOpened = 0;
  final calls = <String>[];
  final outcomes = <String, ExportOutcome>{};
  final createsAlbum = <String>{};
  final gates = <String, Completer<void>>{};
  void Function(String id)? onCall;

  @override
  Future<bool> requestPermission() async {
    permissionAsks++;
    return allow;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<ExportOutcome> exportToAlbum(
    VaultItemModel item, {
    required String album,
    void Function()? onAlbumCreated,
    MediaProgressCallback? onProgress,
  }) async {
    calls.add(item.id);
    onCall?.call(item.id);
    final g = gates[item.id];
    if (g != null) await g.future;
    if (createsAlbum.contains(item.id)) onAlbumCreated?.call();
    return outcomes[item.id] ?? ExportOutcome.saved;
  }
}

List<VaultItemModel> _items(int n, {String? folderId}) => [
  for (var i = 1; i <= n; i++) fakeItem('$i', folderId: folderId),
];

FolderAlbumJob _job(
  FakeAlbumExporter ex,
  List<VaultItemModel> items, {
  AlbumFreeSpace? free,
  SessionTicketProvider? ticket,
  Set<String> saved = const {},
}) => FolderAlbumJob(
  exporter: ex,
  items: items,
  album: 'Viajes',
  freeSpace: free,
  sessionTicket: ticket,
  alreadySaved: saved,
);

typedef SessionTicketProvider = SessionTicket? Function();

class AlbumSaver implements AlbumPhotoSaver {
  bool allow = true;
  int permissionAsks = 0;
  Object? failFor;
  final saved = <String>[];
  final paths = <String>[];
  bool createdAlbum = false;
  void Function()? afterSave;

  @override
  Future<bool> requestAddPermission() async {
    permissionAsks++;
    return allow;
  }

  @override
  Future<void> openSettings() async {}

  Future<bool> _save(File f, String name, String album, String kind) async {
    if (failFor == name) throw const FileSystemException('x');
    expect(f.existsSync(), isTrue);
    paths.add(f.path);
    saved.add('$kind:$album:$name');
    afterSave?.call();
    return createdAlbum;
  }

  @override
  Future<bool> saveImageToAlbum(
    File file, {
    required String filename,
    required String album,
  }) => _save(file, filename, album, 'img');

  @override
  Future<bool> saveVideoToAlbum(
    File file, {
    required String filename,
    required String album,
  }) => _save(file, filename, album, 'vid');

  @override
  Future<void> saveImage(File file, {required String filename}) async =>
      fail('no debe usarse sin álbum');

  @override
  Future<void> saveVideo(File file, {required String filename}) async =>
      fail('no debe usarse sin álbum');
}

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('albumNameFor', () {
    test('limpia separadores, controles y vacíos', () {
      expect(albumNameFor('Viajes 2025'), 'Viajes 2025');
      expect(albumNameFor('a/b\\c:d'), 'a b c d');
      expect(albumNameFor('  ..oculta  '), 'oculta');
      expect(albumNameFor('///'), 'Kern');
      expect(albumNameFor('x' * 200).length, 80);
    });
  });

  group('FolderAlbumJob', () {
    test('guarda todo con progreso «N de M» y avisa cada guardado', () async {
      final ex = FakeAlbumExporter();
      final seen = <String>[];
      final j = FolderAlbumJob(
        exporter: ex,
        items: _items(3),
        album: 'A',
        onSaved: seen.add,
      );
      final progress = <int>[];
      j.addListener(() => progress.add(j.runDone));
      final end = await j.start();
      expect(end, AlbumJobEnd.completed);
      expect(j.savedCount, 3);
      expect(j.failedCount, 0);
      expect(j.runTotal, 3);
      expect(seen, ['1', '2', '3']);
      expect(progress, containsAllInOrder([0, 1, 2, 3]));
      expect(ex.permissionAsks, 1);
    });

    test('un error por archivo no detiene el lote; reintento solo los que '
        'faltan', () async {
      final ex = FakeAlbumExporter()
        ..outcomes['2'] = ExportOutcome.failed
        ..outcomes['4'] = ExportOutcome.failed;
      final j = _job(ex, _items(5));
      expect(await j.start(), AlbumJobEnd.completed);
      expect(j.savedCount, 3);
      expect(j.failedIds, {'2', '4'});
      expect(ex.calls, ['1', '2', '3', '4', '5']);

      ex.calls.clear();
      ex.outcomes['2'] = ExportOutcome.saved;
      expect(await j.start(), AlbumJobEnd.completed);
      expect(ex.calls, ['2', '4'], reason: 'solo los que faltaron');
      expect(j.savedCount, 4);
      expect(j.failedIds, {'4'});
      expect(ex.permissionAsks, 1, reason: 'el permiso se pide una vez');
    });

    test('excepción del exportador cuenta como error de ese archivo', () async {
      final ex = _Throwing();
      final j = FolderAlbumJob(exporter: ex, items: _items(2), album: 'A');
      expect(await j.start(), AlbumJobEnd.completed);
      expect(j.failedCount, 1);
      expect(j.savedCount, 1);
    });

    test('cancelar a mitad: queda lo pendiente y se reanuda sin repetir', () async {
      final ex = FakeAlbumExporter()..gates['2'] = Completer<void>();
      final j = _job(ex, _items(4));
      final fut = j.start();
      await _until(() => ex.calls.contains('2'));
      j.cancel();
      ex.gates['2']!.complete();
      expect(await fut, AlbumJobEnd.cancelled);
      expect(j.savedIds, {'1', '2'});
      expect(j.pendingCount, 2);
      expect(ex.calls, ['1', '2']);

      ex.calls.clear();
      expect(await j.start(), AlbumJobEnd.completed);
      expect(ex.calls, ['3', '4']);
      expect(j.savedCount, 4);
    });

    test('pausar detiene el avance; reanudar continúa', () async {
      final ex = FakeAlbumExporter()..gates['1'] = Completer<void>();
      final j = _job(ex, _items(3));
      final fut = j.start();
      await _until(() => ex.calls.contains('1'));
      j.pause();
      ex.gates['1']!.complete();
      await _until(() => j.runDone == 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ex.calls, ['1'], reason: 'en pausa no empieza otro archivo');
      expect(j.isPaused, isTrue);
      j.resume();
      expect(await fut, AlbumJobEnd.completed);
      expect(ex.calls, ['1', '2', '3']);
    });

    test('cancelar estando en pausa termina', () async {
      final ex = FakeAlbumExporter()..gates['1'] = Completer<void>();
      final j = _job(ex, _items(3));
      final fut = j.start();
      await _until(() => ex.calls.contains('1'));
      j.pause();
      ex.gates['1']!.complete();
      await _until(() => j.runDone == 1);
      j.cancel();
      expect(await fut, AlbumJobEnd.cancelled);
      expect(ex.calls, ['1']);
    });

    test('permiso denegado: no exporta nada; luego se puede reintentar', () async {
      final ex = FakeAlbumExporter()..allow = false;
      final j = _job(ex, _items(3));
      expect(await j.start(), AlbumJobEnd.permissionDenied);
      expect(ex.calls, isEmpty);
      expect(j.savedCount, 0);
      ex.allow = true;
      expect(await j.start(), AlbumJobEnd.completed);
      expect(j.savedCount, 3);
      expect(ex.permissionAsks, 2);
    });

    test('permiso retirado a mitad del lote: se detiene', () async {
      final ex = FakeAlbumExporter()
        ..outcomes['2'] = ExportOutcome.permissionDenied;
      final j = _job(ex, _items(3));
      expect(await j.start(), AlbumJobEnd.permissionDenied);
      expect(ex.calls, ['1', '2']);
      expect(j.savedIds, {'1'});
    });

    test('sin espacio: avisa y no empieza el archivo; con espacio sigue', () async {
      final ex = FakeAlbumExporter();
      var free = 1024;
      final j = _job(ex, _items(3), free: () async => free);
      expect(await j.start(), AlbumJobEnd.noSpace);
      expect(ex.calls, isEmpty);
      free = 1 << 40;
      expect(await j.start(), AlbumJobEnd.completed);
      expect(j.savedCount, 3);
    });

    test('espacio que se acaba a mitad: deja lo guardado y los pendientes', () async {
      final ex = FakeAlbumExporter();
      var free = 1 << 40;
      ex.onCall = (id) {
        if (id == '2') free = 10;
      };
      final j = _job(ex, _items(4), free: () async => free);
      expect(await j.start(), AlbumJobEnd.noSpace);
      expect(j.savedIds, {'1', '2'});
      expect(j.pendingCount, 2);
    });

    test('espacio desconocido (null) no bloquea', () async {
      final j = _job(FakeAlbumExporter(), _items(2), free: () async => null);
      expect(await j.start(), AlbumJobEnd.completed);
    });

    test('bloqueo a mitad: el exportador lo informa y el lote se abandona', () async {
      final ex = FakeAlbumExporter()
        ..outcomes['2'] = ExportOutcome.cancelledByLock;
      final j = _job(ex, _items(4));
      expect(await j.start(), AlbumJobEnd.locked);
      expect(ex.calls, ['1', '2']);
      expect(j.savedIds, {'1'});
    });

    test('bloqueo entre archivos (ticket inválido): no empieza otro', () async {
      final ex = FakeAlbumExporter();
      final t = _Ticket();
      final j = FolderAlbumJob(
        exporter: ex,
        items: _items(4),
        album: 'A',
        sessionTicket: () => t,
      );
      ex.onCall = (id) {
        if (id == '2') t.valid = false;
      };
      expect(await j.start(), AlbumJobEnd.locked);
      expect(ex.calls, ['1', '2']);
    });

    test('sin ticket al empezar (bloqueada): locked sin exportar', () async {
      final ex = FakeAlbumExporter();
      final j = FolderAlbumJob(
        exporter: ex,
        items: _items(2),
        album: 'A',
        sessionTicket: () => null,
      );
      expect(await j.start(), AlbumJobEnd.locked);
      expect(ex.calls, isEmpty);
      expect(ex.permissionAsks, 0);
    });

    test('álbum ya existente (no lo crea): todo se añade sin aviso', () async {
      final ex = FakeAlbumExporter();
      final j = _job(ex, _items(3));
      expect(await j.start(), AlbumJobEnd.completed);
    });

    test('iOS: si crear el álbum se repite, se detiene (sin álbumes '
        'repetidos)', () async {
      final ex = FakeAlbumExporter()..createsAlbum.addAll({'1', '2'});
      final j = _job(ex, _items(5));
      expect(await j.start(), AlbumJobEnd.albumUnsupported);
      expect(ex.calls, ['1', '2']);
      expect(j.savedCount, 2);
    });

    test('alreadySaved se salta y no cuenta en «N de M»', () async {
      final ex = FakeAlbumExporter();
      final j = _job(ex, _items(4), saved: {'1', '3'});
      expect(await j.start(), AlbumJobEnd.completed);
      expect(ex.calls, ['2', '4']);
      expect(j.runTotal, 2);
    });
  });

  group('FolderAlbumService', () {
    test('collect: solo fotos/videos de la carpeta; subcarpetas opcional', () async {
      final repo = FakeVaultRepository(
        folders: [
          fakeFolder('f', 'Viajes'),
          fakeFolder('g', 'Playa', parentId: 'f'),
        ],
        items: [
          fakeItem('a', folderId: 'f'),
          fakeItem('b', folderId: 'f', mime: 'video/mp4', name: 'v.mp4'),
          fakeItem('c', folderId: 'f', mime: 'application/pdf', name: 'd.pdf'),
          fakeItem('d', folderId: 'g'),
          fakeItem('e'),
        ],
      );
      final s = FolderAlbumService(
        repository: repo,
        exporter: FakeAlbumExporter(),
      );
      expect((await s.collect('f')).map((i) => i.id), ['a', 'b']);
      expect(
        (await s.collect('f', includeSubfolders: true)).map((i) => i.id),
        unorderedEquals(['a', 'b', 'd']),
      );
    });

    test('recuerda lo guardado en la sesión; reset lo olvida y cancela', () async {
      final ex = FakeAlbumExporter()..gates['2'] = Completer<void>();
      final items = _items(3, folderId: 'f');
      final s = FolderAlbumService(
        repository: FakeVaultRepository(items: items),
        exporter: ex,
      );
      final job = s.createJob(folderId: 'f', folderName: 'Viajes', items: items);
      final fut = job.start();
      await _until(() => ex.calls.contains('2'));
      s.reset(); // bloqueo: cancela
      ex.gates['2']!.complete();
      expect(await fut, AlbumJobEnd.cancelled);
      expect(s.alreadySaved('f', items), 0, reason: 'se olvida al bloquear');
    });

    test('segunda vez: omite los guardados; skipSaved=false repite todo', () async {
      final ex = FakeAlbumExporter();
      final items = _items(3, folderId: 'f');
      final s = FolderAlbumService(
        repository: FakeVaultRepository(items: items),
        exporter: ex,
      );
      await s.createJob(folderId: 'f', folderName: 'V', items: items).start();
      expect(s.alreadySaved('f', items), 3);
      ex.calls.clear();
      final again = s.createJob(folderId: 'f', folderName: 'V', items: items);
      await again.start();
      expect(ex.calls, isEmpty, reason: 'sin duplicados');
      final all = s.createJob(
        folderId: 'f',
        folderName: 'V',
        items: items,
        skipSaved: false,
      );
      await all.start();
      expect(ex.calls, ['1', '2', '3']);
    });
  });

  group('VaultMediaExporter.exportToAlbum (cifrado real)', () {
    late F6Env env;
    late PlainTempManager temp;
    late VaultMediaOpener opener;
    late AlbumSaver saver;

    List<FileSystemEntity> leftovers() => AppPaths.tmpPlainDir.existsSync()
        ? AppPaths.tmpPlainDir.listSync()
        : const [];

    setUp(() async {
      env = F6Env();
      await env.setUp();
      temp = PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir);
      opener = VaultMediaOpener(
        fetcher: env.fetcher,
        filesKey: env.session.filesKeyFor,
        temp: temp,
        streaming: false,
      );
      saver = AlbumSaver();
    });
    tearDown(() => env.tearDown());

    VaultMediaExporter exporter() => VaultMediaExporter(
      opener: opener,
      saver: saver,
      sessionTicket: () => env.session.isUnlocked ? env.session.ticket() : null,
    );

    test('lote con un fallo en medio: sigue, y no quedan temporales', () async {
      final a = await env.addCloudItem('a', plain: _bytes(3000), name: 'a.jpg');
      final b = await env.addCloudItem('b', plain: _bytes(3000), name: 'b.jpg');
      final c = await env.addCloudItem(
        'c',
        plain: _bytes(3000),
        name: 'c.mov',
        mime: 'video/quicktime',
      );
      saver.failFor = 'b.jpg';
      final ex = exporter();
      final job = FolderAlbumJob(
        exporter: ex,
        items: [a, b, c],
        album: 'Viajes',
        sessionTicket: () => env.session.ticket(),
      );
      expect(await job.start(), AlbumJobEnd.completed);
      expect(saver.saved, ['img:Viajes:a.jpg', 'vid:Viajes:c.mov']);
      expect(job.failedIds, {'b'});
      expect(saver.permissionAsks, 1);
      expect(leftovers(), isEmpty);
      expect(temp.activeCount, 0);
      for (final p in saver.paths) {
        expect(File(p).existsSync(), isFalse);
      }

      saver.failFor = null;
      saver.saved.clear();
      expect(await job.start(), AlbumJobEnd.completed);
      expect(saver.saved, ['img:Viajes:b.jpg'], reason: 'solo el que faltó');
      expect(leftovers(), isEmpty);
    });

    test('permiso denegado: no descifra nada', () async {
      final a = await env.addCloudItem('a', plain: _bytes(500));
      saver.allow = false;
      final job = FolderAlbumJob(
        exporter: exporter(),
        items: [a],
        album: 'X',
      );
      expect(await job.start(), AlbumJobEnd.permissionDenied);
      expect(saver.saved, isEmpty);
      expect(leftovers(), isEmpty);
    });

    test('bloqueo a mitad del lote: se abandona y no quedan temporales', () async {
      final items = [
        for (final id in ['a', 'b', 'c'])
          await env.addCloudItem(id, plain: _bytes(2000), name: '$id.jpg'),
      ];
      saver.afterSave = () {
        if (saver.saved.length == 1) env.session.clear();
      };
      final job = FolderAlbumJob(
        exporter: exporter(),
        items: items,
        album: 'X',
        sessionTicket: () => env.session.isUnlocked ? env.session.ticket() : null,
      );
      expect(await job.start(), AlbumJobEnd.locked);
      expect(saver.saved.length, 1);
      expect(leftovers(), isEmpty);
      expect(temp.activeCount, 0);
    });

    test('saver sin soporte de álbum: unsupported', () async {
      final a = await env.addCloudItem('a', plain: _bytes(500));
      final plain = VaultMediaExporter(opener: opener, saver: _PlainSaver());
      expect(
        await plain.exportToAlbum(a, album: 'X'),
        ExportOutcome.unsupported,
      );
      expect(leftovers(), isEmpty);
    });
  });

  group('diálogo «Guardar en Fotos como álbum»', () {
    late FakeAlbumExporter ex;
    late FolderAlbumService service;

    Future<void> open(
      WidgetTester t, {
      List<VaultItemModel>? items,
      FolderAlbumService? svc,
    }) async {
      ex = FakeAlbumExporter();
      final repo = FakeVaultRepository(
        folders: [
          fakeFolder('f', 'Viajes'),
          fakeFolder('g', 'Playa', parentId: 'f'),
        ],
        items:
            items ??
            [
              fakeItem('1', folderId: 'f'),
              fakeItem('2', folderId: 'f'),
              fakeItem('3', folderId: 'g'),
            ],
      );
      service = svc ?? FolderAlbumService(repository: repo, exporter: ex);
      usePhoneSize(t);
      await t.pumpWidget(
        testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAlbumExportDialog(
                context,
                service: service,
                folderId: 'f',
                folderName: 'Viajes',
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await t.tap(find.text('abrir'));
      await t.pumpAndSettle();
    }

    testWidgets('avisa SIN cifrar, muestra el álbum y cancelar no guarda', (
      t,
    ) async {
      await open(t);
      expect(find.textContaining('SIN cifrar'), findsOneWidget);
      expect(find.textContaining('«Viajes»'), findsOneWidget);
      expect(find.textContaining('con 2 foto'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('album-cancel-confirm')));
      await t.pumpAndSettle();
      expect(ex.calls, isEmpty);
      expect(ex.permissionAsks, 0);
    });

    testWidgets('incluir subcarpetas cambia la cuenta', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('album-include-sub')));
      await t.pumpAndSettle();
      expect(find.textContaining('con 3 foto'), findsOneWidget);
    });

    testWidgets('confirmar guarda todo y muestra el resumen', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(ex.calls, ['1', '2']);
      expect(find.textContaining('Guardados: 2 de 2'), findsOneWidget);
      expect(find.textContaining('Con error: 0'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('album-close')));
      await t.pumpAndSettle();
      expect(find.byType(AlbumExportDialog), findsNothing);
    });

    testWidgets('error por archivo: resumen y reintentar solo el que faltó', (
      t,
    ) async {
      await open(t);
      ex.outcomes['2'] = ExportOutcome.failed;
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(find.textContaining('Guardados: 1 de 2'), findsOneWidget);
      expect(find.textContaining('Con error: 1'), findsOneWidget);
      ex.outcomes.clear();
      ex.calls.clear();
      await t.tap(find.byKey(const ValueKey('album-retry')));
      await t.pumpAndSettle();
      expect(ex.calls, ['2']);
      expect(find.textContaining('Guardados: 2 de 2'), findsOneWidget);
    });

    testWidgets('progreso «N de M», pausar, reanudar y cancelar', (t) async {
      await open(t);
      ex.gates['1'] = Completer<void>();
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pump();
      await t.pump();
      expect(find.text('0 de 2'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('album-pause')));
      await t.pump();
      expect(find.text('Reanudar'), findsOneWidget);
      ex.gates['1']!.complete();
      await t.pump();
      await t.pump();
      expect(find.text('En pausa: 1 de 2'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('album-pause')));
      await t.pumpAndSettle();
      expect(find.textContaining('Guardados: 2 de 2'), findsOneWidget);
    });

    testWidgets('cancelar a mitad muestra lo guardado', (t) async {
      await open(t);
      ex.gates['2'] = Completer<void>();
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pump();
      await t.pump();
      await t.tap(find.byKey(const ValueKey('album-cancel')));
      ex.gates['2']!.complete();
      await t.pumpAndSettle();
      expect(find.textContaining('Cancelado'), findsOneWidget);
      expect(find.textContaining('Guardados: 2 de 2'), findsOneWidget);
    });

    testWidgets('permiso denegado: mensaje y Abrir ajustes', (t) async {
      await open(t);
      ex.allow = false;
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(find.textContaining('Sin permiso'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('album-settings')));
      expect(ex.settingsOpened, 1);
      ex.allow = true;
      await t.tap(find.byKey(const ValueKey('album-retry')));
      await t.pumpAndSettle();
      expect(find.textContaining('Guardados: 2 de 2'), findsOneWidget);
    });

    testWidgets('sin espacio: aviso claro', (t) async {
      ex = FakeAlbumExporter();
      final items = [fakeItem('1', folderId: 'f')];
      final svc = FolderAlbumService(
        repository: FakeVaultRepository(items: items),
        exporter: ex,
        freeSpace: () async => 10,
      );
      await open(t, items: items, svc: svc);
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(find.textContaining('espacio libre'), findsOneWidget);
    });

    testWidgets('repetir: avisa de los ya guardados y ofrece solo los que '
        'faltan o repetir todo', (t) async {
      await open(t);
      ex.outcomes['2'] = ExportOutcome.failed;
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('album-close')));
      await t.pumpAndSettle();
      ex.outcomes.clear();
      ex.calls.clear();
      await t.tap(find.text('abrir'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-already')), findsOneWidget);
      expect(find.textContaining('Ya guardaste 1 de 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('album-repeat-all')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(ex.calls, ['2'], reason: 'sin duplicar el 1');
    });

    testWidgets('carpeta sin fotos: no hay botón de guardar', (t) async {
      await open(t, items: const []);
      expect(find.byKey(const ValueKey('album-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-confirm')), findsNothing);
    });

    testWidgets('bloqueo a mitad: el diálogo se cierra solo', (t) async {
      await open(t);
      ex.outcomes['1'] = ExportOutcome.cancelledByLock;
      await t.tap(find.byKey(const ValueKey('export-confirm')));
      await t.pumpAndSettle();
      expect(find.byType(AlbumExportDialog), findsNothing);
    });
  });

  group('menú de carpeta en la cuadrícula', () {
    Future<void> openHome(WidgetTester t, {bool withService = true}) async {
      final repo = FakeVaultRepository(
        folders: [fakeFolder('d1', 'Viajes')],
        items: [fakeItem('1'), fakeItem('2', folderId: 'd1')],
      );
      usePhoneSize(t);
      await t.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(
              repo,
              folderAlbums: withService
                  ? FolderAlbumService(
                      repository: repo,
                      exporter: FakeAlbumExporter(),
                    )
                  : null,
            ),
            initialColumns: 3,
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(seconds: 1));
    }

    testWidgets('con UNA carpeta seleccionada aparece la acción y abre el '
        'aviso', (t) async {
      await openHome(t);
      await t.longPress(find.byType(FolderTile));
      await t.pump(const Duration(seconds: 1));
      expect(find.byTooltip('Guardar en Fotos como álbum'), findsOneWidget);
      await t.tap(find.byTooltip('Guardar en Fotos como álbum'));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('SIN cifrar'), findsOneWidget);
      expect(find.byType(AlbumExportDialog), findsOneWidget);
    });

    testWidgets('con un archivo seleccionado no aparece', (t) async {
      await openHome(t);
      await t.longPress(find.text('IMG_1.jpg'));
      await t.pump(const Duration(seconds: 1));
      expect(find.byTooltip('Guardar en Fotos como álbum'), findsNothing);
    });

    testWidgets('sin servicio no aparece', (t) async {
      await openHome(t, withService: false);
      await t.longPress(find.byType(FolderTile));
      await t.pump(const Duration(seconds: 1));
      expect(find.byTooltip('Guardar en Fotos como álbum'), findsNothing);
    });
  });
}

class _PlainSaver implements PhotoSaver {
  @override
  Future<bool> requestAddPermission() async => true;
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> saveImage(File file, {required String filename}) async {}
  @override
  Future<void> saveVideo(File file, {required String filename}) async {}
}

class _Throwing implements AlbumMediaExporter {
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> openSettings() async {}
  @override
  Future<ExportOutcome> exportToAlbum(
    VaultItemModel item, {
    required String album,
    void Function()? onAlbumCreated,
    MediaProgressCallback? onProgress,
  }) async {
    if (item.id == '1') throw StateError('x');
    return ExportOutcome.saved;
  }
}

class _Ticket implements SessionTicket {
  bool valid = true;
  @override
  VaultSlot get slot => VaultSlot.primary;
  @override
  int get epoch => 1;
  @override
  bool get isValid => valid;
  @override
  void check() {
    if (!valid) throw SessionChangedException();
  }
}

Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 400 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue, reason: 'condición no alcanzada');
}
