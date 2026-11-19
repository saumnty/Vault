// Fase 5 (v2): pantalla Papelera y texto de confirmación de borrado.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/trash/trash_repository.dart';
import 'package:vault/features/settings/trash_screen.dart';
import 'package:vault/features/vault/models/browser_entry.dart';
import 'package:vault/features/vault/services/trash_service.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/features/vault/widgets/vault_sheets.dart';

import '../support/f6_env.dart';
import '../support/ui_helpers.dart';

void main() {
  late F6Env env;
  late TrashService service;
  late List<RemoteDeleteTarget> remote;
  const day = Duration.millisecondsPerDay;
  int now = 100 * day;

  Future<void> boot(WidgetTester t) async {
    await t.runAsync(() async {
      env = F6Env();
      await env.setUp();
      now = 100 * day;
      remote = [];
      service = TrashService(
        repository: TrashRepository(dbProvider: () => env.vdb.database),
        fileCleaner: (ids) async {
          for (final id in ids) {
            final f = AppPaths.resolve(AppPaths.vaultRelativePath(id));
            if (f.existsSync()) f.deleteSync();
          }
        },
        remoteDeleter: (x) async => remote.addAll(x),
        nowMs: () => now,
      );
      await env.addFolder('f1');
      await env.addCloudItem('a', name: 'Playa.jpg');
      await env.addCloudItem('b', folderId: 'f1');
      await env.addCloudItem('c', folderId: 'f1');
      await service.trash([
        FileEntry((await env.items.getItem('a'))!),
        FolderEntry((await env.items.getFolder('f1'))!),
      ]);
      now += 5 * day;
    });
    addTearDown(() => t.runAsync(env.tearDown));
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester t) async {
    usePhoneSize(t);
    await t.pumpWidget(testApp(TrashScreen(service: service)));
    await settle(t);
  }

  testWidgets('lista lo borrado con días restantes y tamaño', (t) async {
    await boot(t);
    await pump(t);
    expect(find.text('Papelera'), findsOneWidget);
    expect(find.textContaining('30 días'), findsWidgets);
    expect(find.text('Playa.jpg'), findsOneWidget);
    expect(find.text('Carpeta f1'), findsOneWidget);
    expect(find.textContaining('Quedan 25 días'), findsNWidgets(2));
    expect(find.textContaining('2 archivo(s)'), findsOneWidget);
    expect(find.text('Vaciar Papelera'), findsOneWidget);
  });

  testWidgets('archivos con miniatura (mismo cargador), video con ▶ y duración, '
      'carpeta con ícono', (t) async {
    await boot(t);
    await t.runAsync(() async {
      await env.addCloudItem('v', name: 'Clip.mp4', mime: 'video/mp4');
      await env.addCloudItem('n', name: 'Sin.jpg', thumb: false);
      final db = await env.vdb.database;
      await db.update(
        'vault_items',
        {'durationMs': 65000},
        where: 'id = ?',
        whereArgs: ['v'],
      );
      await service.trash([
        FileEntry((await env.items.getItem('v'))!),
        FileEntry((await env.items.getItem('n'))!),
      ]);
    });
    final asked = <String>[];
    // 1x1 PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    usePhoneSize(t);
    await t.pumpWidget(
      testApp(
        TrashScreen(
          service: service,
          thumbnailLoader: (item) async {
            asked.add(item.id);
            return MemoryImage(png);
          },
        ),
      ),
    );
    await settle(t);
    // Se pide miniatura de los archivos que la tienen, no de la carpeta ni
    // del que no tiene.
    expect(asked.toSet(), {'a', 'v'});
    expect(find.byKey(const ValueKey('trash-thumb-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('trash-thumb-v')), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    // Sin miniatura: ícono de respaldo por tipo.
    expect(find.text('Sin.jpg'), findsOneWidget);
  });

  testWidgets('restaurar saca el elemento de la lista', (t) async {
    await boot(t);
    await pump(t);
    await t.tap(find.byTooltip('Restaurar Playa.jpg'));
    await settle(t);
    expect(find.text('Playa.jpg'), findsNothing);
    expect(find.text('Restaurado: Playa.jpg'), findsOneWidget);
    final live = await t.runAsync(() => env.items.getItemsByFolder(null));
    expect(live!.map((i) => i.id), ['a']);
  });

  testWidgets('eliminar definitivamente pide confirmación y borra', (t) async {
    await boot(t);
    await pump(t);
    await t.tap(find.byTooltip('Eliminar definitivamente Playa.jpg'));
    await settle(t);
    expect(find.textContaining('NO se puede deshacer'), findsOneWidget);
    // Cancelar: nada cambia.
    await t.tap(find.text('Cancelar'));
    await settle(t);
    expect(find.text('Playa.jpg'), findsOneWidget);
    expect(remote, isEmpty);
    // Confirmar.
    await t.tap(find.byTooltip('Eliminar definitivamente Playa.jpg'));
    await settle(t);
    await t.tap(find.text('Eliminar definitivamente').last);
    await settle(t);
    expect(find.text('Playa.jpg'), findsNothing);
    expect(remote.map((r) => r.itemId), ['a']);
  });

  testWidgets('vaciar la Papelera elimina todo y muestra el estado vacío', (
    t,
  ) async {
    await boot(t);
    await pump(t);
    await t.tap(find.text('Vaciar Papelera'));
    await settle(t);
    await t.tap(find.text('Vaciar Papelera').last);
    await settle(t);
    expect(find.byKey(const ValueKey('trash-empty')), findsOneWidget);
    expect(remote.map((r) => r.itemId).toSet(), {'a', 'b', 'c'});
  });

  testWidgets('papelera vacía: mensaje y sin botón de vaciar', (t) async {
    await boot(t);
    await t.runAsync(() => service.emptyAll());
    await pump(t);
    expect(find.byKey(const ValueKey('trash-empty')), findsOneWidget);
    expect(find.text('Vaciar Papelera'), findsNothing);
  });

  group('confirmación de borrado', () {
    Future<void> open(WidgetTester t, {required bool toTrash}) async {
      usePhoneSize(t);
      await t.pumpWidget(
        testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showConfirmDeleteSheet(
                context,
                count: 2,
                includesFolders: true,
                toTrash: toTrash,
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await t.tap(find.text('abrir'));
      await t.pumpAndSettle();
    }

    testWidgets('con papelera: restaurable 30 días, luego permanente', (
      t,
    ) async {
      await open(t, toTrash: true);
      expect(find.text('¿Mover 2 elementos a la Papelera?'), findsOneWidget);
      expect(find.textContaining('Ajustes > Papelera'), findsOneWidget);
      expect(find.textContaining('30 días'), findsOneWidget);
      expect(find.textContaining('Google Drive'), findsOneWidget);
      expect(find.text('Mover a la Papelera'), findsOneWidget);
    });

    testWidgets('sin papelera: texto de borrado permanente', (t) async {
      await open(t, toTrash: false);
      expect(find.text('¿Eliminar 2 elementos?'), findsOneWidget);
      expect(find.textContaining('no se puede deshacer'), findsOneWidget);
    });
  });
}
