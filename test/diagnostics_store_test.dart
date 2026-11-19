// D78 (cambio de cuenta atascado, parte B, punto 5): diagnóstico persistente
// cifrado (`diag_events`, últimos 500), solo con la principal, fuera del
// snapshot, con «Borrar» y sobreviviendo a bloquear y reabrir.
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
}
