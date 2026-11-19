// D78 (cambio de cuenta atascado, parte B, punto 6): el probe de la
// restauración devuelve un inventario (solo conteos y tamaños) y el mensaje
// dice qué encontró en vez del genérico «No hay respaldo».
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/features/onboarding/restore_flow.dart';

import 'support/fake_cloud.dart';
import 'support/fakes.dart';
import 'support/scripted_restore.dart';
import 'support/ui_helpers.dart';

const _id1 = '0b9f6f1e-3c1a-4d2e-9f00-1a2b3c4d5e6f';
const _id2 = '1c8e5d2f-4b2a-4e3f-8a11-2b3c4d5e6f70';

CloudFile _f(String name, int size) =>
    CloudFile(id: name, name: name, size: size);

/// Palabras que nunca deben salir en el mensaje (datos personales).
void _expectNoPersonalData(String text) {
  for (final s in ['@', _id1, _id2, '.vault', '.thumb', 'snapshot', 'json']) {
    expect(text.contains(s), isFalse, reason: '«$s» en «$text»');
  }
}

void main() {
  group('CloudInventory y el mensaje', () {
    test('cuenta vacía: «ningún dato de Kern»', () {
      final inv = CloudInventory.of(const []);
      expect(inv.isEmpty, isTrue);
      final (title, msg) = describeRestoreProbe(
        RestoreProbeResult.noBackup,
        inv,
      );
      expect(title, 'No hay respaldo en esta cuenta de Google');
      expect(msg, contains('no tiene ningún dato de Kern'));
    });

    test('solo una copia de la base de datos (el caso del iPhone)', () {
      final inv = CloudInventory.of([_f('vault_db.snapshot', 120 * 1024)]);
      expect(inv.snapshots, 1);
      expect(inv.snapshotBytes, 120 * 1024);
      final (title, msg) = describeRestoreProbe(
        RestoreProbeResult.noBackup,
        inv,
      );
      expect(title, 'Falta el respaldo de tus llaves');
      expect(
        msg,
        startsWith(
          'Solo hay una copia de la base de datos (120 KB) en esta cuenta, '
          'pero falta el respaldo de la llave',
        ),
      );
      expect(msg, contains('ábrela allí'));
      _expectNoPersonalData(msg);
    });

    test('índice + archivos + miniaturas, sin respaldo', () {
      final inv = CloudInventory.of([
        _f('vault_db.snapshot', 2 * 1024 * 1024),
        _f('$_id1.vault', 1000),
        _f('$_id2.vault', 3000),
        _f('$_id1.thumb', 50),
        _f('otra_cosa.txt', 5),
      ]);
      expect(inv.files, 2);
      expect(inv.fileBytes, 4000);
      expect(inv.thumbs, 1);
      expect(inv.others, 1);
      final (_, msg) = describeRestoreProbe(RestoreProbeResult.noBackup, inv);
      expect(
        msg,
        startsWith(
          'Hay una copia de la base de datos (2.0 MB), 2 archivos cifrados y '
          '1 miniatura en esta cuenta',
        ),
      );
      _expectNoPersonalData(msg);
    });

    test('respaldo sin índice: incompleto con la cifra de archivos', () {
      final inv = CloudInventory.of([
        _f('recovery_backup.json', 300),
        _f('$_id1.vault', 1000),
      ]);
      expect(inv.backups, 1);
      expect(inv.backupGens, {1});
      final (title, msg) = describeRestoreProbe(
        RestoreProbeResult.incomplete,
        inv,
      );
      expect(title, 'El respaldo está incompleto');
      expect(msg, contains('Hay 1 archivo cifrado.'));
      _expectNoPersonalData(msg);
    });

    test('respaldos inválidos: cuántos', () {
      final inv = CloudInventory.of([
        _f('recovery_backup.json', 300),
        _f('recovery_backup.k2.json', 300),
      ]);
      expect(inv.backupGens, {1, 2});
      final (title, msg) = describeRestoreProbe(
        RestoreProbeResult.invalid,
        inv,
      );
      expect(title, 'El respaldo no es válido');
      expect(msg, contains('2 respaldos de llaves'));
    });

    test('varias generaciones de índices', () {
      final inv = CloudInventory.of([
        _f('vault_db.snapshot', 1024),
        _f('vault_db.k2.snapshot', 1024),
      ]);
      expect(inv.snapshots, 2);
      expect(inv.snapshotGens, {1, 2});
      final (_, msg) = describeRestoreProbe(RestoreProbeResult.noBackup, inv);
      expect(msg, startsWith('Solo hay 2 copias de la base de datos (2 KB)'));
    });

    test('sin inventario (desconocido): el mensaje de siempre', () {
      final (title, _) = describeRestoreProbe(
        RestoreProbeResult.noBackup,
        null,
      );
      expect(title, 'No hay respaldo en esta cuenta de Google');
    });
  });

  test('probe deja el inventario y lo registra solo con números', () async {
    DiagnosticsBuffer.instance.clear();
    final cloud = FakeCloudStorage(email: 'persona@example.com');
    await cloud.uploadBytes(
      bytes: Uint8List.fromList(utf8.encode('x' * 2048)),
      name: 'vault_db.snapshot',
    );
    await cloud.uploadBytes(
      bytes: Uint8List.fromList([1, 2, 3]),
      name: '$_id1.vault',
    );
    final svc = RestoreService(
      cloud: cloud,
      auth: AuthController(
        storage: InMemorySecureStore(),
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
      ),
      prefs: SyncPreferences(InMemorySecureStore()),
    );
    expect(await svc.probe(), RestoreProbeResult.noBackup);
    final inv = svc.lastInventory!;
    expect(inv.snapshots, 1);
    expect(inv.snapshotBytes, 2048);
    expect(inv.files, 1);
    final line = DiagnosticsBuffer.instance.entries
        .map((e) => e.message)
        .firstWhere((m) => m.startsWith('Restauración: noBackup'));
    expect(line, contains('índices=1'));
    expect(line, contains('archivos=1'));
    _expectNoPersonalData(line);
  });

  testWidgets('la pantalla dice qué encontró', (tester) async {
    usePhoneSize(tester);
    final svc = ScriptedRestoreService()
      ..probeResult = RestoreProbeResult.noBackup
      ..inventory = CloudInventory.of([_f('vault_db.snapshot', 120 * 1024)]);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SafeArea(
            child: RestoreFlow(
              service: svc,
              onBack: () {},
              onCreateNew: () {},
              onRestored: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Iniciar sesión con Google'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Falta el respaldo de tus llaves'), findsOneWidget);
    expect(
      find.textContaining('Solo hay una copia de la base de datos (120 KB)'),
      findsOneWidget,
    );
    expect(find.text('No hay respaldo en esta cuenta de Google'), findsNothing);
    expect(find.text('Usar otra cuenta'), findsOneWidget);
  });
}
