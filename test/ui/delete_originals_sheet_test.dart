import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/gallery/delete_originals_sheet.dart';
import 'package:vault/features/vault/widgets/vault_sheets.dart';
import 'package:vault/shared/widgets/blur_sheet.dart';

import '../support/ui_helpers.dart';

VaultItemModel _item(String id, String name, int size) => VaultItemModel(
  id: id,
  name: name,
  encryptedPath: 'vault/$id.vault',
  fileSize: size,
  mimeType: 'image/png',
  createdAt: '2026-01-01T00:00:00',
);

Future<void> _open(
  WidgetTester tester, {
  required Future<List<VaultItemModel>> Function() load,
  required Future<List<String>> Function(List<VaultItemModel>) confirm,
  required void Function(int?) onResult,
}) async {
  usePhoneSize(tester);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final n = await showBlurSheet<int>(
              context,
              builder: (_) =>
                  DeleteOriginalsContent(load: load, confirm: confirm),
            );
            onResult(n);
          },
          child: const Text('abrir'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lista solo los verificados, avisa y no borra hasta confirmar', (
    tester,
  ) async {
    var confirmCalls = 0;
    int? result = -1;
    await _open(
      tester,
      load: () async => [
        _item('1', 'foto_a.png', 2048),
        _item('2', 'v.mp4', 10),
      ],
      confirm: (items) async {
        confirmCalls++;
        return [for (final i in items) i.id];
      },
      onResult: (n) => result = n,
    );
    expect(find.text('¿Borrar 2 originales del dispositivo?'), findsOneWidget);
    expect(find.text('foto_a.png'), findsOneWidget);
    expect(find.textContaining('no se puede deshacer'), findsOneWidget);
    expect(
      find.textContaining('verificada en tu Google Drive'),
      findsOneWidget,
    );
    expect(confirmCalls, 0); // mostrar la lista no borra nada
    await tester.tap(find.text('Borrar 2 originales'));
    await tester.pumpAndSettle();
    expect(confirmCalls, 1);
    expect(result, 2);
  });

  testWidgets('cancelar no borra nada', (tester) async {
    var confirmCalls = 0;
    int? result = -1;
    await _open(
      tester,
      load: () async => [_item('1', 'foto_a.png', 2048)],
      confirm: (items) async {
        confirmCalls++;
        return ['1'];
      },
      onResult: (n) => result = n,
    );
    expect(find.text('Borrar original'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(confirmCalls, 0);
    expect(result, 0);
  });

  testWidgets('sin verificados: mensaje y ningún botón de borrar', (
    tester,
  ) async {
    int? result = -1;
    await _open(
      tester,
      load: () async => const [],
      confirm: (_) async => throw StateError('no debe llamarse'),
      onResult: (n) => result = n,
    );
    expect(find.text('No hay originales para borrar'), findsOneWidget);
    expect(find.textContaining('Borrar original'), findsNothing);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(result, 0);
  });

  testWidgets('si el borrado falla devuelve 0 sin romper', (tester) async {
    int? result = -1;
    await _open(
      tester,
      load: () async => [_item('1', 'a.png', 5)],
      confirm: (_) async => throw StateError('falla'),
      onResult: (n) => result = n,
    );
    await tester.tap(find.text('Borrar original'));
    await tester.pumpAndSettle();
    expect(result, 0);
  });

  testWidgets('importar archivo: la hoja ya NO ofrece eliminar el original', (
    tester,
  ) async {
    usePhoneSize(tester);
    bool? result = true;
    var closed = false;
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showImportConfirmSheet(context);
              closed = true;
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.textContaining('eliminar original'), findsNothing);
    expect(find.textContaining('no se toca'), findsOneWidget);
    await tester.tap(find.text('Cifrar e importar'));
    await tester.pumpAndSettle();
    expect(result, isFalse); // false = importar conservando el original
    expect(closed, isTrue);

    closed = false;
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
