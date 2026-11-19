import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/core/logging/vault_log.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/features/settings/diagnostics_screen.dart';

const _header = DiagnosticsHeader(
  version: '1.0.0 (1)',
  platform: 'test 1',
  aes: 'Dart',
  argon2: 'Dart',
  mode: 'debug',
);

void main() {
  late DiagnosticsBuffer saved;
  setUp(() {
    saved = DiagnosticsBuffer.instance;
    DiagnosticsBuffer.instance = DiagnosticsBuffer();
  });
  tearDown(() {
    DiagnosticsBuffer.instance = saved;
    VaultLog.reset();
  });

  test('búfer circular con tope y categorías', () {
    final b = DiagnosticsBuffer(capacity: 3);
    for (var i = 0; i < 5; i++) {
      b.add(DiagLevel.debug, 'sync', 'm$i');
    }
    expect(b.length, 3);
    expect(b.entries.first.message, 'm2');
    expect(b.entries.last.category, 'sync');
    expect(b.export().split('\n'), hasLength(3));
    b.clear();
    expect(b.isEmpty, isTrue);
  });

  test('el tope por defecto es 500', () {
    final b = DiagnosticsBuffer();
    for (var i = 0; i < 700; i++) {
      b.add(DiagLevel.debug, 'ui', 'x');
    }
    expect(b.length, 500);
  });

  test('saneado: correos, rutas, UUID y tokens no salen', () {
    final b = DiagnosticsBuffer();
    b.add(
      DiagLevel.error,
      'import',
      'user@example.com /data/user/0/app/foto.jpg C:\\Users\\a\\b.png '
      '123e4567-e89b-12d3-a456-426614174000 '
      'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo= deadbeefdeadbeefdeadbeefdeadbeef',
    );
    final out = b.export();
    for (final s in [
      'example.com',
      'foto.jpg',
      'Users',
      '123e4567',
      'QUJDREVG',
      'deadbeef',
    ]) {
      expect(out, isNot(contains(s)));
    }
    expect(out, contains('<redacted>'));
  });

  test('VaultLog no imprime en release pero sí alimenta el búfer', () {
    final out = <String>[];
    VaultLog.sink = out.add;
    VaultLog.isDebug = () => false;
    VaultLog.d('Paso', category: 'migration');
    VaultLog.e('Falló', const FormatException('/ruta/secreta'), 'thumbs');
    expect(out, isEmpty);
    final e = DiagnosticsBuffer.instance.entries;
    expect(e, hasLength(2));
    expect(e[0].category, 'migration');
    expect(e[1].message, 'Falló (FormatException)');
    expect(e[1].level, DiagLevel.error);
    expect(DiagnosticsBuffer.instance.export(), isNot(contains('secreta')));
  });

  test('se borra al bloquear la sesión', () {
    final session = VaultSession.create();
    session.addOnClear(DiagnosticsBuffer.instance.clear);
    VaultLog.d('algo');
    expect(DiagnosticsBuffer.instance.isEmpty, isFalse);
    session.clear();
    expect(DiagnosticsBuffer.instance.isEmpty, isTrue);
  });

  Widget app(DiagnosticsBuffer b) => MaterialApp(
    home: DiagnosticsScreen(buffer: b, headerLoader: () async => _header),
  );

  testWidgets('estado vacío', (tester) async {
    await tester.pumpWidget(app(DiagnosticsBuffer()));
    await tester.pump();
    expect(find.text('Sin eventos registrados'), findsOneWidget);
    expect(find.textContaining('AES: Dart'), findsOneWidget);
  });

  testWidgets('muestra líneas y copia al portapapeles', (tester) async {
    final b = DiagnosticsBuffer()..add(DiagLevel.debug, 'sync', 'Hola fijo');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(app(b));
    await tester.pump();
    expect(find.textContaining('[sync] Hola fijo'), findsOneWidget);
    await tester.tap(find.text('Copiar'));
    await tester.pump();
    expect(copied, contains('Hola fijo'));
    expect(copied, contains('Versión: 1.0.0 (1)'));
    expect(find.text('Diagnóstico copiado'), findsOneWidget);
  });
}
