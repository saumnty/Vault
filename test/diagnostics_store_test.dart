// D78 (cambio de cuenta atascado, parte B, punto 5): diagnóstico persistente
// cifrado (`diag_events`, últimos 500), solo con la principal, fuera del
// snapshot, con «Borrar» y sobreviviendo a bloquear y reabrir.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/core/logging/diagnostics_store.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/features/settings/diagnostics_screen.dart';

import 'support/f9_env.dart';
import 'support/ui_helpers.dart';

void main() {
  late PhoneA a;
  late DiagnosticsBuffer buffer;
  var secondary = false;
  var suspended = false;

  DiagnosticsStore newStore() => DiagnosticsStore(
    buffer: buffer,
    dbProvider: () => a.vdb.database,
    primaryOpen: () => a.session.isUnlockedAs(VaultSlot.primary),
    secondaryOpen: () => secondary,
    suspended: () => suspended,
    flushDelay: const Duration(milliseconds: 5),
  )..install();

  Future<int> rows() async {
    final db = await a.vdb.database;
    return (await db.rawQuery('SELECT COUNT(*) AS n FROM diag_events'))
            .first['n']
        as int;
  }

  setUp(() async {
    secondary = false;
    suspended = false;
    buffer = DiagnosticsBuffer();
    a = PhoneA();
    await a.setUp();
  });

  tearDown(() async => a.tearDown());

  test('anillo de 500: solo los últimos', () async {
    final store = newStore();
    for (var i = 0; i < 620; i++) {
      buffer.add(DiagLevel.debug, 'sync', 'evento $i');
    }
    await store.flush();
    expect(await rows(), 500);
    final list = await store.entries();
    expect(list, hasLength(500));
    expect(list.first.message, 'evento 120');
    expect(list.last.message, 'evento 619');
    store.uninstall();
  });

  test('sobrevive a bloquear y a reiniciar (otra instancia)', () async {
    final store = newStore();
    buffer.add(DiagLevel.error, 'migration', 'Cambio de cuenta en pausa');
    await store.flush();
    store.uninstall();
    a.session.clear(); // bloqueo: la memoria se vacía como siempre
    buffer.clear();
    // Mientras está bloqueada no se lee la tabla (solo lo de memoria).
    final again = newStore();
    expect(await again.entries(), isEmpty);
    // Evento con la sesión bloqueada (p. ej. el flush al bloquear): espera.
    buffer.add(DiagLevel.debug, 'sync', 'Snapshot de la BD subido');
    expect(again.pendingCount, 1);
    expect(await a.auth.unlockWithPin('123456'), isTrue);
    final list = await again.entries();
    expect(list.map((e) => e.message), [
      'Cambio de cuenta en pausa',
      'Snapshot de la BD subido',
    ]);
    expect(list.first.level, DiagLevel.error);
    expect(list.first.category, 'migration');
    again.uninstall();
  });

  test('con la adicional abierta no se guarda nada; al cambiar de bóveda se '
      'descarta lo pendiente', () async {
    final store = newStore();
    secondary = true;
    buffer.add(DiagLevel.debug, 'ui', 'de la adicional');
    expect(store.pendingCount, 0);
    secondary = false;
    a.session.clear();
    buffer.add(DiagLevel.debug, 'ui', 'tardía');
    expect(store.pendingCount, 1);
    buffer.slotChanged(); // AuthController al abrir la otra bóveda (B5)
    expect(store.pendingCount, 0);
    expect(await a.auth.unlockWithPin('123456'), isTrue);
    await store.flush();
    expect(await rows(), 0);
    store.uninstall();
  });

  test('suspendido (re-cifrado / copia del snapshot): no escribe', () async {
    final store = newStore();
    suspended = true;
    buffer.add(DiagLevel.debug, 'sync', 'durante el re-cifrado');
    await store.flush();
    expect(await rows(), 0);
    expect(store.pendingCount, 1);
    suspended = false;
    await store.flush();
    expect(await rows(), 1);
    store.uninstall();
  });

  test('Borrar: tabla, pendientes y memoria', () async {
    final store = newStore();
    buffer.add(DiagLevel.debug, 'sync', 'uno');
    await store.flush();
    buffer.add(DiagLevel.debug, 'sync', 'dos');
    await store.clearAll();
    expect(await rows(), 0);
    expect(store.pendingCount, 0);
    expect(buffer.isEmpty, isTrue);
    store.uninstall();
  });

  test('el snapshot exportado NO lleva el diagnóstico; el local sí', () async {
    final store = newStore();
    for (var i = 0; i < 20; i++) {
      buffer.add(DiagLevel.debug, 'sync', 'e$i');
    }
    await store.flush();
    expect(await rows(), 20);
    final copy = await a.vdb.exportEncryptedSnapshot();
    final db = await databaseFactoryFfi.openDatabase(copy.file.path);
    try {
      final n =
          (await db.rawQuery('SELECT COUNT(*) AS n FROM diag_events')).first['n']
              as int;
      expect(n, 0);
      // El resto de la BD viaja igual.
      expect(await db.query('vault_items'), isA<List<Object?>>());
    } finally {
      await db.close();
      await copy.file.delete();
    }
    expect(await rows(), 20);
    store.uninstall();
  });

  test('privacidad: lo guardado va saneado (sin correos, rutas ni UUID)', () async {
    final store = newStore();
    buffer.add(
      DiagLevel.error,
      'auth',
      'user@example.com /var/mobile/foto.jpg '
          '123e4567-e89b-12d3-a456-426614174000',
    );
    await store.flush();
    final db = await a.vdb.database;
    final msg = (await db.query('diag_events')).single['message'] as String;
    for (final s in ['example.com', '/var/', 'foto.jpg', '123e4567']) {
      expect(msg.contains(s), isFalse, reason: s);
    }
    store.uninstall();
  });

  testWidgets('pantalla: muestra lo guardado, estado de la nube y Borrar '
      'con confirmación', (tester) async {
    late DiagnosticsStore store;
    await tester.runAsync(() async {
      store = newStore();
      buffer.add(DiagLevel.debug, 'sync', 'Sincronización iniciada');
      await store.flush();
    });
    usePhoneSize(tester);
    await tester.pumpWidget(
      testApp(
        DiagnosticsScreen(
          buffer: buffer,
          store: store,
          headerLoader: () async => const DiagnosticsHeader(
            version: '1',
            platform: 'test',
            aes: 'Dart',
            argon2: 'Dart',
            mode: 'debug',
          ),
          cloudStateLoader: () async => 'Cambio de cuenta: ninguno',
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(find.textContaining('Sincronización iniciada'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('diagnostics-cloud-state')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('diagnostics-clear')));
    await tester.pumpAndSettle();
    expect(find.text('¿Borrar el diagnóstico?'), findsOneWidget);
    await tester.tap(find.text('Borrar diagnóstico').last);
    // Consultas reales (hilo de sqflite) intercaladas con los frames.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Sin eventos registrados'), findsOneWidget);
    expect(await tester.runAsync(rows), 0);
    store.uninstall();
  });

  // ---------------------------------------------------------------- D83
  // BUG-1: el diagnóstico dejaba de mostrar eventos nuevos. Causa demostrada:
  // una operación con la BD que no terminaba dejaba `_flushing` puesto para
  // siempre: todo `flush()` posterior (incluido el paso «diagnóstico» del
  // desbloqueo, que se esperaba) y `entries()` (la pantalla) se quedaban
  // esperando aunque la BD volviera a responder.
  group('D83 (BUG-1): sin esperas sin fin ni fallos silenciosos', () {
    var hang = false;
    var throwing = false;
    Completer<Database>? hung;

    DiagnosticsStore guarded({int capacity = 500}) => DiagnosticsStore(
      buffer: buffer,
      dbProvider: () {
        if (hang) return (hung ??= Completer<Database>()).future;
        if (throwing) throw const _FakeDbFailure();
        return a.vdb.database;
      },
      primaryOpen: () => a.session.isUnlockedAs(VaultSlot.primary),
      secondaryOpen: () => secondary,
      suspended: () => suspended,
      capacity: capacity,
      flushDelay: const Duration(milliseconds: 5),
      opTimeout: const Duration(milliseconds: 150),
      maxBackoff: const Duration(milliseconds: 40),
    )..install();

    setUp(() {
      hang = false;
      throwing = false;
      hung = null;
    });

    Future<void> settle([int ms = 400]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('una apertura de la BD colgada no cuelga flush ni la pantalla; al '
        'volver la BD se guarda todo', () async {
      final store = guarded();
      buffer.add(DiagLevel.debug, 'import', 'Importación iniciada');
      await store.flush();
      expect(await rows(), 1);
      hang = true; // p. ej. `database` esperando algo que nunca llega
      buffer.add(DiagLevel.debug, 'picker', 'Selector abierto');
      final sw = Stopwatch()..start();
      await store.flush(); // antes: no volvía nunca
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(store.health.value.failures, greaterThan(0));
      expect(store.health.value.lastError, 'tiempo agotado');
      expect(store.health.value.unsaved, 1);
      // La pantalla no se cuelga: lo guardado + lo pendiente.
      final shown = await store.entries().timeout(const Duration(seconds: 2));
      expect(shown.last.message, 'Selector abierto');
      // La BD vuelve: la escritura colgada termina (o se reintenta) y nada se
      // pierde ni se duplica.
      hang = false;
      hung!.complete(a.vdb.database);
      buffer.add(DiagLevel.debug, 'migration', 'Guarda aplicada');
      await settle();
      await store.flush();
      final list = await store.entries();
      expect(list.map((e) => e.message), [
        'Importación iniciada',
        'Selector abierto',
        'Guarda aplicada',
      ]);
      expect(store.pendingCount, 0);
      expect(store.health.value.healthy, isTrue);
      store.uninstall();
    });

    test('fallo de la BD a mitad: conserva lo pendiente, lo muestra, lo '
        'cuenta y reintenta solo (sin eventos nuevos)', () async {
      final store = guarded();
      buffer.add(DiagLevel.debug, 'app', 'antes');
      await store.flush();
      final db = await a.vdb.database;
      // INSERT imposible (tabla ausente): DatabaseException real.
      await db.execute('ALTER TABLE diag_events RENAME TO diag_tmp');
      buffer.add(DiagLevel.debug, 'verify', 'Verificación iniciada');
      buffer.add(DiagLevel.error, 'verify', 'Verificación fallida');
      await store.flush();
      final h = store.health.value;
      expect(h.failures, greaterThan(0));
      expect(h.unsaved, 2);
      expect(h.lastError, isNot(contains('/')));
      expect(h.describe(), contains('no pudo guardar 2 eventos'));
      expect(store.pendingCount, 2);
      // Visible en memoria aunque no se pueda leer la tabla.
      final shown = await store.entries();
      expect(shown.map((e) => e.message), contains('Verificación fallida'));
      expect(store.health.value.readFailed, isTrue);
      // La tabla vuelve: el reintento con espera lo guarda SIN que llegue
      // ningún evento nuevo.
      await db.execute('ALTER TABLE diag_tmp RENAME TO diag_events');
      await settle();
      expect(store.pendingCount, 0);
      expect(await rows(), 3);
      final list = await store.entries();
      expect(list.map((e) => e.message), [
        'antes',
        'Verificación iniciada',
        'Verificación fallida',
      ]);
      expect(store.health.value.healthy, isTrue);
      store.uninstall();
    });

    test('mientras no se puede guardar, lo pendiente se acota a capacity y '
        'lo descartado se cuenta', () async {
      final store = guarded(capacity: 5);
      throwing = true;
      for (var i = 0; i < 3; i++) {
        buffer.add(DiagLevel.debug, 'x', 'e$i');
      }
      await store.flush();
      expect(store.health.value.failures, greaterThan(0));
      for (var i = 3; i < 10; i++) {
        buffer.add(DiagLevel.debug, 'x', 'e$i');
      }
      expect(store.pendingCount, 5);
      expect(store.health.value.dropped, 5);
      expect(store.health.value.describe(), contains('Descartados'));
      throwing = false;
      await settle();
      expect(await rows(), 5);
      // «Borrar diagnóstico» deja el estado limpio.
      await store.clearAll();
      expect(store.health.value.healthy, isTrue);
      store.uninstall();
    });

    test('bloquear/desbloquear varias veces, cerrar la BD a mitad y re-crear '
        'el almacén (servicios nuevos): ningún evento se pierde', () async {
      var store = guarded();
      final expected = <String>[];
      for (var round = 0; round < 4; round++) {
        for (var i = 0; i < 5; i++) {
          final m = 'r$round e$i';
          expected.add(m);
          buffer.add(DiagLevel.debug, 'x', m);
          // Copia del snapshot a mitad (cierra la conexión y suspende).
          if (i == 2) {
            final copy = await a.vdb.exportEncryptedSnapshot();
            await copy.file.delete();
          }
        }
        // Bloqueo («Bloquear ahora»): BD cerrada y memoria vaciada.
        a.session.clear();
        await a.vdb.close();
        buffer.clear();
        final late = 'bloqueada $round';
        expected.add(late);
        buffer.add(DiagLevel.debug, 'sync', late);
        // Misma bóveda: slotChanged NO se llama (no se descarta nada).
        expect(await a.auth.unlockWithPin('123456'), isTrue);
        if (round == 1) {
          // Servicios re-creados: un almacén nuevo se engancha al búfer.
          await store.flush();
          store.uninstall();
          store = guarded();
        }
        await store.flush();
      }
      final list = await store.entries();
      expect(list.map((e) => e.message), expected);
      expect(store.health.value.healthy, isTrue);
      store.uninstall();
    });

    test('suspendido mucho tiempo: lo pendiente sigue visible; al terminar '
        'se guarda solo', () async {
      final store = guarded();
      suspended = true;
      buffer.add(DiagLevel.debug, 'sync', 'durante la copia');
      await settle(100);
      expect(await rows(), 0);
      expect(
        (await store.entries()).map((e) => e.message),
        contains('durante la copia'),
      );
      suspended = false;
      await settle(100);
      expect(await rows(), 1);
      store.uninstall();
    });

    testWidgets('pantalla: muestra «no pudo guardar N eventos»', (
      tester,
    ) async {
      late DiagnosticsStore store;
      await tester.runAsync(() async {
        store = guarded();
        throwing = true;
        buffer.add(DiagLevel.debug, 'sync', 'Sincronización iniciada');
        await store.flush();
      });
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          DiagnosticsScreen(
            buffer: buffer,
            store: store,
            headerLoader: () async => const DiagnosticsHeader(
              version: '1',
              platform: 'test',
              aes: 'Dart',
              argon2: 'Dart',
              mode: 'debug',
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final health = find.byKey(const ValueKey('diagnostics-store-health'));
      expect(health, findsOneWidget);
      expect(
        tester.widget<Text>(health).data,
        contains('no pudo guardar 1 evento'),
      );
      expect(find.textContaining('Sincronización iniciada'), findsOneWidget);
      throwing = false;
      // Reintento con espera (temporizadores de la prueba) + consultas reales.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      await tester.pump();
      expect(health, findsNothing);
      store.uninstall();
    });
  });
}

class _FakeDbFailure implements Exception {
  const _FakeDbFailure();
}
