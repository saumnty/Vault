import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_service.dart';

import 'support/f9_env.dart';

/// Política del snapshot de la BD (F9): fresco, tras las subidas, solo si hay
/// cambios, con debounce y al bloquear.
void main() {
  late PhoneA a;
  var snapshots = 0;
  late List<String> uploadsAtSnapshot;

  /// Servicio de sync de A con un snapshot que anota qué había subido ya y el
  /// contenido real de la BD (ids de Drive de los items).
  SyncService make({
    bool wake = false,
    Duration debounce = const Duration(milliseconds: 40),
  }) {
    a.sync.dispose();
    final svc = SyncService(
      cloud: a.cloud,
      queue: a.queue,
      items: a.items,
      network: a.net,
      prefs: a.prefs,
      isUnlocked: () => a.session.isUnlocked,
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: a.auth.exportRecoveryBackup,
      snapshotProvider: () async {
        snapshots++;
        uploadsAtSnapshot = List.of(a.cloud.uploadedNames);
        final rows = [
          ...await a.items.getItemsByFolder(null),
          ...await a.items.getItemsByFolder('f1'),
        ];
        final f = File('${a.dbPath}.snapshot');
        await f.writeAsString(
          jsonEncode([
            for (final r in rows) {'id': r.id, 'drive': r.driveFileId},
          ]),
        );
        return f;
      },
      nowMs: () => a.now,
      random: Random(1),
      scheduleWakeups: wake,
      snapshotDebounce: debounce,
    );
    a.sync = svc;
    return svc;
  }

  setUp(() async {
    snapshots = 0;
    uploadsAtSnapshot = [];
    a = PhoneA();
    await a.setUp();
    await a.addFolder('f1', 'Carpeta');
  });

  tearDown(() async {
    VaultDataRepository.onDataChanged = null;
    await a.tearDown();
  });

  test('se toma DESPUÉS de las subidas e incluye sus driveFileId', () async {
    final sync = make();
    await a.addItem('i1', 'a.jpg');
    await a.addItem('i2', 'b.jpg', folderId: 'f1');
    await sync.run(manual: true);

    expect(snapshots, 1);
    // Cuando se tomó, ya estaban subidos los archivos y las miniaturas.
    expect(
      uploadsAtSnapshot,
      containsAll(['i1.vault', 'i2.vault', 'i1.thumb', 'i2.thumb']),
    );
    // ...y la copia remota lleva los driveFileId de lo recién subido.
    final remote = jsonDecode(
      utf8.decode(a.cloud.bytesOf('vault_db.snapshot')!),
    ) as List;
    final byId = {for (final r in remote) r['id']: r['drive']};
    expect(byId['i1'], a.cloud.byName('i1.vault')!.id);
    expect(byId['i2'], a.cloud.byName('i2.vault')!.id);
    // El snapshot es lo ÚLTIMO que se sube.
    expect(a.cloud.uploadedNames.last, 'vault_db.snapshot');
    expect(await a.prefs.getDirtyAt(), isNull);
  });

  test('sin cambios no se sube snapshot (ni con la cola vacía)', () async {
    final sync = make();
    await a.addItem('i1', 'a.jpg');
    await sync.run(manual: true);
    expect(snapshots, 1);

    a.now += 60 * 1000; // un minuto después, sin cambios
    await sync.run(manual: true);
    await sync.run(manual: true);
    expect(snapshots, 1);
  });

  test('un cambio sin subidas (renombrar, mover, carpeta) dispara snapshot',
      () async {
    final sync = make();
    VaultDataRepository.onDataChanged = sync.notifyDataChanged;
    await a.addItem('i1', 'a.jpg');
    await sync.run(manual: true);
    expect(snapshots, 1);

    await a.items.renameItem('i1', 'nuevo.jpg');
    await Future<void>.delayed(Duration.zero);
    expect(await a.prefs.getDirtyAt(), isNotNull);
    await sync.run(manual: true);
    expect(snapshots, 2);

    await a.items.moveItem('i1', 'f1');
    await a.addFolder('f3', 'Otra');
    await a.items.setItemOffline('i1', true);
    await sync.run(manual: true);
    expect(snapshots, 3);

    await a.items.deleteItem('i1');
    await sync.run(manual: true);
    expect(snapshots, 4);

    // Estado derivado (syncStatus / acceso) NO ensucia el snapshot.
    await a.addItem('i9', 'z.jpg');
    await sync.run(manual: true);
    final n = snapshots;
    await a.items.touchLastAccessed('i9');
    await sync.run(manual: true);
    expect(snapshots, n);
  });

  test('la regla de 6 h sigue vigente aunque no haya cambios', () async {
    final sync = make();
    await a.addItem('i1', 'a.jpg');
    await sync.run(manual: true);
    expect(snapshots, 1);
    a.now += const Duration(hours: 6).inMilliseconds + 1;
    await sync.run(manual: true);
    expect(snapshots, 2);
  });

  test('con la cola ocupada (red caída) no hay snapshot parcial', () async {
    final sync = make();
    a.net.set(NetworkKind.none);
    await a.addItem('i1', 'a.jpg');
    await sync.run(manual: true);
    expect(snapshots, 0);
    expect(await a.prefs.getDirtyAt(), isNull); // aún no hubo cambio de datos
    a.net.set(NetworkKind.wifi);
    await sync.run(manual: true);
    expect(snapshots, 1);
  });

  test('un cambio durante el snapshot lo deja sucio para el siguiente',
      () async {
    final sync = make();
    VaultDataRepository.onDataChanged = sync.notifyDataChanged;
    await a.addItem('i1', 'a.jpg');
    await sync.run(manual: true);
    expect(snapshots, 1);

    await a.items.renameItem('i1', 'x.jpg');
    await Future<void>.delayed(Duration.zero);
    // Simula un cambio posterior a la toma de la copia.
    final dirtyBefore = await a.prefs.getDirtyAt();
    expect(dirtyBefore, isNotNull);
    await a.prefs.markSnapshotDone(a.now + 10, takenAtMs: a.now - 1);
    expect(await a.prefs.getDirtyAt(), isNotNull); // cambio > toma: sigue sucio
    await a.prefs.markSnapshotDone(a.now + 10, takenAtMs: a.now + 5);
    expect(await a.prefs.getDirtyAt(), isNull);
  });

  test('debounce: varios cambios seguidos = una sola pasada', () async {
    final sync = make(wake: true, debounce: const Duration(milliseconds: 120));
    VaultDataRepository.onDataChanged = sync.notifyDataChanged;
    await a.addItem('i1', 'a.jpg'); // insertItem notifica
    await a.items.renameItem('i1', 'b.jpg');
    await a.items.renameItem('i1', 'c.jpg');
    // Antes del debounce no ha corrido nada.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(snapshots, 0);
    expect(a.cloud.uploadCalls, 0);
    // Pasado el debounce corre UNA vez: sube y toma el snapshot.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(snapshots, 1);
    expect(a.cloud.byName('i1.vault'), isNotNull);
    // Nueva ráfaga: otra pasada.
    await a.items.renameItem('i1', 'd.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(snapshots, 2);
  });

  group('al bloquear (best-effort)', () {
    test('con cambios pendientes toma y sube la copia sin esperar', () async {
      final sync = make();
      VaultDataRepository.onDataChanged = sync.notifyDataChanged;
      await a.addItem('i1', 'a.jpg');
      await sync.run(manual: true);
      expect(snapshots, 1);

      await a.items.renameItem('i1', 'tras-ultimo.jpg');
      await Future<void>.delayed(Duration.zero);
      await sync.flushSnapshotBeforeLock();
      expect(snapshots, 2); // la copia se toma ANTES de cerrar la sesión
      // La subida sigue sola, sin llaves ni BD.
      for (var i = 0; i < 20 && await a.prefs.getDirtyAt() != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await a.prefs.getDirtyAt(), isNull);
      expect(a.cloud.uploadedNames.last, 'vault_db.snapshot');
    });

    test('sin cambios, sin cuenta o sin red permitida: no hace nada', () async {
      final sync = make();
      await a.addItem('i1', 'a.jpg');
      await sync.run(manual: true);
      final n = snapshots;
      await sync.flushSnapshotBeforeLock(); // limpio
      expect(snapshots, n);

      await a.prefs.markDirty(a.now);
      a.net.set(NetworkKind.none);
      await sync.flushSnapshotBeforeLock();
      expect(snapshots, n);

      a.net.set(NetworkKind.mobile); // solo Wi-Fi por defecto
      await sync.flushSnapshotBeforeLock();
      expect(snapshots, n);

      a.net.set(NetworkKind.wifi);
      await a.cloud.signOut();
      await sync.flushSnapshotBeforeLock();
      expect(snapshots, n);
      expect(await a.prefs.getDirtyAt(), isNotNull); // sigue pendiente
    });

    test('si falla la subida, la marca sucio persiste', () async {
      final sync = make();
      await a.addItem('i1', 'a.jpg');
      await sync.run(manual: true);
      await a.prefs.markDirty(a.now + 1);
      a.cloud.failure = (op) =>
          op == 'upload' ? const CloudNoNetworkException() : null;
      await sync.flushSnapshotBeforeLock();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await a.prefs.getDirtyAt(), isNotNull);
    });
  });
}
