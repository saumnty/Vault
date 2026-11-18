import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/gallery/import_preferences.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/sync/storage_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/features/settings/widgets/settings_widgets.dart';
import 'package:vault/features/vault/home_vault_screen.dart';

import '../support/settings_support.dart';
import '../support/fakes.dart';
import '../support/ui_helpers.dart';

const pin = settingsTestPin;
const mb = settingsMb;

/// Pantalla alta para que ListView construya todas las secciones.
void _useTallPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 3000 * 2);
  addTearDown(tester.view.reset);
}

Future<SettingsTestEnv> _open(
  WidgetTester tester, {
  bool withSync = true,
  bool withStorage = true,
  BiometricAvailability bio = BiometricAvailability.available,
}) async {
  _useTallPhone(tester);
  final e = SettingsTestEnv();
  e.bio.available = bio;
  await tester.runAsync(e.init);
  addTearDown(e.dispose);
  await tester.pumpWidget(
    e.screen(withSync: withSync, withStorage: withStorage),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
  return e;
}

Future<void> _digits(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.bySemanticsLabel('Dígito $d'));
    await tester.pump();
  }
}

Future<void> _crypto(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Teclea [digits], pulsa Continuar y espera la derivación de llaves.
Future<void> _submitPin(WidgetTester tester, String digits) async {
  await _digits(tester, digits);
  if (digits.length < 6) await tester.tap(find.text('Continuar'));
  await _crypto(tester);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('muestra todas las secciones y la versión', (tester) async {
    await _open(tester);
    for (final t in [
      'Ajustes',
      'Seguridad',
      'Importación',
      'Almacenamiento',
      'Sincronización y cuenta',
      'Acerca de',
      'Cambiar PIN',
      'Desbloqueo biométrico',
      'Autobloqueo',
      'Proteger pantalla',
      'Generar nuevo código de recuperación',
      'Bloquear ahora',
      'Calidad de video por defecto',
      'Borrar originales cuando estén en la nube',
      'Límite de caché',
      'Liberar espacio sin conexión',
      'Vaciar caché ahora',
      'Solo Wi-Fi',
      'Cuenta de Google',
      'Sincronizar ahora',
      'Cerrar sesión de Google',
      'Versión',
      'Privacidad',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('1.2.3 (45)'), findsOneWidget);
    expect(find.text('santy@example.com'), findsOneWidget);
  });

  testWidgets('Sincronización y cuenta explica la carpeta oculta de Drive', (
    tester,
  ) async {
    await _open(tester);
    expect(
      find.textContaining('carpeta oculta de tu Google Drive'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Más información'));
    await tester.tap(find.text('Más información'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Administrar aplicaciones > Vault'),
      findsOneWidget,
    );
    expect(find.textContaining('verificación en dos pasos'), findsOneWidget);
    // El interruptor de borrar originales usa el mismo texto aclaratorio.
    expect(
      find.textContaining('Apagado por defecto. Solo se borran'),
      findsOneWidget,
    );
  });

  testWidgets('sin servicios de nube/almacenamiento oculta esas secciones', (
    tester,
  ) async {
    await _open(tester, withSync: false, withStorage: false);
    expect(find.text('Almacenamiento'), findsNothing);
    expect(find.text('Sincronización y cuenta'), findsNothing);
    expect(find.text('Seguridad'), findsOneWidget);
  });

  testWidgets('accesibilidad: áreas táctiles y etiquetas', (tester) async {
    final handle = tester.ensureSemantics();
    await _open(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  group('Seguridad', () {
    testWidgets('Autobloqueo: elige un tiempo, aplica en caliente y persiste', (
      tester,
    ) async {
      final e = await _open(tester);
      expect(find.text('1 minuto'), findsOneWidget); // por defecto
      await tester.tap(find.text('Autobloqueo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15 segundos'));
      await tester.pumpAndSettle();
      expect(e.autoLock.delay, AutoLockDelay.seconds15); // en caliente
      expect(e.store.data[AutoLockPreferences.delayKey], '15000');
      expect(find.text('15 segundos'), findsOneWidget); // valor visible
    });

    testWidgets('Proteger pantalla: desactivar pide confirmación y persiste', (
      tester,
    ) async {
      final e = await _open(tester);
      Switch sw() => tester.widget<Switch>(
        find.descendant(
          of: find.widgetWithText(SwitchListTile, 'Proteger pantalla'),
          matching: find.byType(Switch),
        ),
      );
      expect(sw().value, isTrue);

      // Cancelar no cambia nada.
      await tester.tap(find.text('Proteger pantalla'));
      await tester.pumpAndSettle();
      expect(find.text('¿Permitir capturas de pantalla?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(sw().value, isTrue);
      expect(e.secureCalls, isEmpty);

      // Confirmar: persiste y aplica FLAG_SECURE=false en caliente.
      await tester.tap(find.text('Proteger pantalla'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desactivar protección'));
      await tester.pumpAndSettle();
      expect(sw().value, isFalse);
      expect(e.store.data[ScreenProtectionPreferences.protectKey], 'false');
      expect(e.secureCalls.last, isFalse);

      // Volver a activar no pide confirmación.
      await tester.tap(find.text('Proteger pantalla'));
      await tester.pumpAndSettle();
      expect(sw().value, isTrue);
      expect(e.store.data[ScreenProtectionPreferences.protectKey], 'true');
      expect(e.secureCalls.last, isTrue);
    });

    testWidgets('Biometría: activar y desactivar', (tester) async {
      final e = await _open(tester);
      Switch sw() => tester.widget<Switch>(
        find.descendant(
          of: find.widgetWithText(SwitchListTile, 'Desbloqueo biométrico'),
          matching: find.byType(Switch),
        ),
      );
      expect(sw().value, isFalse);
      await tester.tap(find.text('Desbloqueo biométrico'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(sw().value, isTrue);
      expect(await e.auth.isBiometricUnlockEnabled(), isTrue);
      expect(e.bio.stored, isNotNull);

      await tester.tap(find.text('Desbloqueo biométrico'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(sw().value, isFalse);
      expect(await e.auth.isBiometricUnlockEnabled(), isFalse);
      expect(e.bio.stored, isNull);
    });

    testWidgets('Biometría cancelada: sigue apagada y avisa', (tester) async {
      final e = await _open(tester);
      e.bio.cancelNext = true;
      await tester.tap(find.text('Desbloqueo biométrico'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Se canceló'), findsOneWidget);
      expect(await e.auth.isBiometricUnlockEnabled(), isFalse);
    });

    testWidgets('Biometría sin huellas registradas: deshabilitada y explica', (
      tester,
    ) async {
      await _open(tester, bio: BiometricAvailability.notEnrolled);
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Desbloqueo biométrico'),
      );
      expect(tile.onChanged, isNull);
      expect(find.textContaining('No disponible: registra'), findsOneWidget);
    });

    testWidgets('Bloquear ahora llama al bloqueo', (tester) async {
      final e = await _open(tester);
      await tester.tap(find.text('Bloquear ahora'));
      await tester.pump();
      expect(e.locks, 1);
    });
  });

  group('Cambiar PIN', () {
    testWidgets('PIN actual, nuevo y confirmación: el nuevo PIN desbloquea y '
        'el viejo no', (tester) async {
      final e = await _open(tester);
      final dekBefore = e.auth.session.keys.dekBytes();
      await tester.tap(find.text('Cambiar PIN'));
      await tester.pumpAndSettle();
      expect(find.text('PIN actual'), findsOneWidget);
      await _submitPin(tester, pin); // 6 dígitos: se envía solo
      expect(find.text('PIN nuevo'), findsOneWidget);
      await _submitPin(tester, '246800');
      expect(find.text('Confirma el PIN nuevo'), findsOneWidget);
      await _submitPin(tester, '246800');
      expect(find.text('PIN cambiado'), findsOneWidget);

      e.auth.lock();
      final reopened = AuthController(
        storage: e.store,
        biometricStore: e.bio,
        kdfParams: fastKdf,
        session: VaultSession.create(),
      );
      final results = await tester.runAsync(
        () async => [
          await reopened.unlockWithPin('246800'),
          await reopened.unlockWithPin(pin),
        ],
      );
      expect(results, [true, false]);
      // Misma DEK: solo se volvió a envolver.
      expect(reopened.session.keys.dekBytes(), dekBefore);
    });

    testWidgets('confirmación distinta: error y no cambia el PIN', (
      tester,
    ) async {
      final e = await _open(tester);
      await tester.tap(find.text('Cambiar PIN'));
      await tester.pumpAndSettle();
      await _submitPin(tester, pin);
      await _submitPin(tester, '246800');
      await _submitPin(tester, '246900');
      expect(find.text('Los PIN no coinciden'), findsOneWidget);
      expect(find.text('PIN cambiado'), findsNothing);
      // Atrás cancela todo.
      await tester.tap(find.byTooltip('Volver').last);
      await tester.pumpAndSettle();
      final ok = await tester.runAsync(() => e.auth.unlockWithPin(pin));
      expect(ok, isTrue);
    });

    testWidgets('el PIN nuevo no puede ser igual al actual', (tester) async {
      await _open(tester);
      await tester.tap(find.text('Cambiar PIN'));
      await tester.pumpAndSettle();
      await _submitPin(tester, pin);
      await _submitPin(tester, pin);
      expect(find.textContaining('distinto del actual'), findsOneWidget);
    });

    testWidgets('PIN actual incorrecto: avisa y vuelve a pedirlo', (
      tester,
    ) async {
      final e = await _open(tester);
      await tester.tap(find.text('Cambiar PIN'));
      await tester.pumpAndSettle();
      await _submitPin(tester, '654321'); // actual incorrecto
      await _submitPin(tester, '246800');
      await _submitPin(tester, '246800');
      expect(find.textContaining('PIN actual no era correcto'), findsOneWidget);
      expect(find.text('PIN actual'), findsOneWidget);
      // Sigue valiendo el PIN de antes.
      final ok = await tester.runAsync(() => e.auth.unlockWithPin(pin));
      expect(ok, isTrue);
      // Ahora con el correcto sí se cambia.
      await _submitPin(tester, pin);
      await _submitPin(tester, '246800');
      await _submitPin(tester, '246800');
      expect(find.text('PIN cambiado'), findsOneWidget);
    });

    testWidgets('bloqueo por demasiados intentos: muestra la espera', (
      tester,
    ) async {
      final e = await _open(tester);
      await tester.runAsync(() async {
        for (var i = 0; i < 8; i++) {
          try {
            await e.auth.unlockWithPin('000000');
          } on PinLockedOutException {
            break;
          }
        }
      });
      expect(await e.auth.pinLockoutRemaining(), isNotNull);
      await tester.tap(find.text('Cambiar PIN'));
      await tester.pumpAndSettle();
      await _submitPin(tester, pin);
      await _submitPin(tester, '246800');
      await _submitPin(tester, '246800');
      expect(find.textContaining('Demasiados intentos'), findsOneWidget);
    });
  });

  group('Rotación de la llave maestra (S-11)', () {
    Future<SettingsTestEnv> openWithRotation(WidgetTester tester) async {
      _useTallPhone(tester);
      final e = SettingsTestEnv();
      await tester.runAsync(e.init);
      addTearDown(e.dispose);
      await tester.pumpWidget(e.screen(rotation: e.rotationService()));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      return e;
    }

    testWidgets('entradas en Seguridad: rotar, código nuevo, comprobar', (
      tester,
    ) async {
      await openWithRotation(tester);
      expect(find.text('Rotar llave maestra'), findsOneWidget);
      expect(find.text('Generar nuevo código de recuperación'), findsOneWidget);
      expect(
        find.textContaining('el código actual no abrirá nada'),
        findsOneWidget,
      );
      expect(find.text('Comprobar mi código'), findsOneWidget);
      expect(find.byKey(const ValueKey('rotation-banner')), findsNothing);
    });

    testWidgets('con una rotación en curso: aviso, PIN y cerrar sesión '
        'deshabilitados', (tester) async {
      final e = await openWithRotation(tester);
      await tester.runAsync(() async {
        await e.auth.unlockWithPin(pin);
        await e.auth.prepareRotation(pin, toGen: 2, accountEmail: 'x@y');
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rotation-banner')), findsOneWidget);
      expect(find.text('Cambio de llave en curso'), findsOneWidget);
      expect(
        find.text('Disponible al terminar el cambio de llave maestra'),
        findsOneWidget,
      );
      for (final t in ['Cambiar PIN', 'Cerrar sesión de Google']) {
        final tile = tester.widget<SettingsTile>(
          find.ancestor(of: find.text(t), matching: find.byType(SettingsTile)),
        );
        expect(tile.onTap, isNull, reason: t);
      }
    });

    testWidgets('Comprobar mi código: vigente y no coincide', (tester) async {
      final e = await openWithRotation(tester);
      final code = await tester.runAsync(() async {
        // Un código conocido para esta bóveda.
        final c = (await e.auth.regenerateRecoveryCode(pin))!;
        return c;
      });
      for (final (typed, expected) in [
        (code!, 'Este código es el vigente'),
        ('ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2', 'No coincide'),
      ]) {
        await tester.tap(find.text('Comprobar mi código'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, typed);
        await tester.tap(find.text('Comprobar'));
        await _crypto(tester);
        await tester.pumpAndSettle();
        expect(find.text(expected), findsOneWidget);
        ScaffoldMessenger.of(
          tester.element(find.text('Ajustes')),
        ).hideCurrentSnackBar();
        await tester.pumpAndSettle();
      }
    });
  });

  group('Generar nuevo código de recuperación', () {
    testWidgets('PIN incorrecto: error y no cambia el respaldo', (
      tester,
    ) async {
      final e = await _open(tester);
      final before = await e.auth.exportRecoveryBackup();
      await tester.tap(find.text('Generar nuevo código de recuperación'));
      await tester.pumpAndSettle();
      await _submitPin(tester, '654321');
      expect(find.text('PIN incorrecto'), findsOneWidget);
      expect(await e.auth.exportRecoveryBackup(), before);
    });

    testWidgets('PIN correcto: muestra el código, exige confirmarlo y '
        'actualiza el respaldo', (tester) async {
      final e = await _open(tester);
      final before = (await e.auth.exportRecoveryBackup())!;
      await tester.tap(find.text('Generar nuevo código de recuperación'));
      await tester.pumpAndSettle();
      await _submitPin(tester, pin);

      expect(find.text('Tu nuevo código'), findsOneWidget);
      expect(find.textContaining('Copiar'), findsNothing);
      final shown = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('recovery-code-box')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data!)
          .join('-');
      expect(RecoveryCode.normalize(shown), isNotNull);
      final after = (await e.auth.exportRecoveryBackup())!;
      expect(after, isNot(before));

      // No se puede salir sin confirmar (atrás no hace nada).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Tu nuevo código'), findsOneWidget);

      await tester.tap(find.text('Ya lo anoté'));
      await tester.pumpAndSettle();
      final label = tester
          .widget<Text>(find.textContaining('Escribe los caracteres'))
          .data!;
      final positions = RegExp(
        r'(\d+)\.º',
      ).allMatches(label).map((m) => int.parse(m.group(1)!)).toList();
      final norm = RecoveryCode.normalize(shown)!;
      await tester.enterText(
        find.byKey(const ValueKey('confirm-code-field')),
        [for (final p in positions) norm[p - 1]].join(),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
      await tester.pumpAndSettle();

      expect(find.text('Ajustes'), findsOneWidget);
      expect(find.textContaining('Código nuevo confirmado'), findsOneWidget);
    });
  });

  group('Importación', () {
    testWidgets('Calidad de video por defecto: elige y persiste', (
      tester,
    ) async {
      final e = await _open(tester);
      expect(find.text('Original'), findsOneWidget);
      await tester.tap(find.text('Calidad de video por defecto'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();
      expect(find.text('720p'), findsOneWidget);
      expect(
        await GalleryImportPreferences(e.store).getVideoQuality(),
        VideoQualityOption.p720,
      );
    });

    testWidgets('Borrar originales: apagado por defecto; activar pide '
        'confirmación', (tester) async {
      final e = await _open(tester);
      Switch sw() => tester.widget<Switch>(
        find.descendant(
          of: find.widgetWithText(
            SwitchListTile,
            'Borrar originales cuando estén en la nube',
          ),
          matching: find.byType(Switch),
        ),
      );
      expect(sw().value, isFalse);
      await tester.tap(find.text('Borrar originales cuando estén en la nube'));
      await tester.pumpAndSettle();
      expect(find.text('¿Borrar originales de la galería?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(sw().value, isFalse);

      await tester.tap(find.text('Borrar originales cuando estén en la nube'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activar'));
      await tester.pumpAndSettle();
      expect(sw().value, isTrue);
      expect(
        await GalleryImportPreferences(e.store).getDeleteOriginalsWhenInCloud(),
        isTrue,
      );
      // Apagar no pide confirmación.
      await tester.tap(find.text('Borrar originales cuando estén en la nube'));
      await tester.pumpAndSettle();
      expect(sw().value, isFalse);
    });
  });

  group('Almacenamiento', () {
    testWidgets('muestra uso de caché y sin conexión y el límite', (
      tester,
    ) async {
      await _open(tester);
      expect(find.text('500 MB'), findsOneWidget);
      expect(
        find.textContaining('Caché: 20,00 MB (4 archivos)'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Sin conexión: 30,00 MB (5 archivos)'),
        findsOneWidget,
      );
    });

    testWidgets('Límite de caché: presets y aplica el elegido', (tester) async {
      final e = await _open(tester);
      await tester.tap(find.text('Límite de caché'));
      await tester.pumpAndSettle();
      for (final t in ['250 MB', '500 MB', '1 GB', '2 GB', '5 GB']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      expect(find.text('Predeterminado'), findsOneWidget);
      await tester.tap(find.text('1 GB'));
      await tester.pumpAndSettle();
      expect(e.storage.calls, ['limit:${1024 * mb}']);
      expect(find.text('1 GB'), findsOneWidget); // valor visible
    });

    testWidgets('Liberar espacio sin conexión: confirma y resume lo liberado', (
      tester,
    ) async {
      final e = await _open(tester);
      await tester.tap(find.text('Liberar espacio sin conexión'));
      await tester.pumpAndSettle();
      expect(find.text('¿Liberar espacio sin conexión?'), findsOneWidget);
      expect(
        find.textContaining('lo pendiente de subir no se toca'),
        findsOneWidget,
      );
      // Cancelar no hace nada.
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(e.storage.calls, isEmpty);

      await tester.tap(find.text('Liberar espacio sin conexión'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Liberar espacio'));
      await tester.pumpAndSettle();
      expect(e.storage.calls, ['free']);
      expect(find.textContaining('Se liberaron 12,00 MB'), findsOneWidget);
    });

    testWidgets('Vaciar caché ahora: confirma y resume', (tester) async {
      final e = await _open(tester);
      await tester.tap(find.text('Vaciar caché ahora'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vaciar caché'));
      await tester.pumpAndSettle();
      expect(e.storage.calls, ['clear']);
      expect(
        find.textContaining('Caché vaciada: 3 archivo(s)'),
        findsOneWidget,
      );
    });

    testWidgets('si no había nada que liberar lo dice', (tester) async {
      final e = await _open(tester);
      e.storage.next = const FreedSpace(files: 0, bytes: 0);
      await tester.tap(find.text('Vaciar caché ahora'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vaciar caché'));
      await tester.pumpAndSettle();
      expect(find.text('No había nada que liberar'), findsOneWidget);
    });
  });

  group('Sincronización y cuenta', () {
    testWidgets('Solo Wi-Fi: por defecto activado; cambiar persiste', (
      tester,
    ) async {
      final e = await _open(tester);
      Switch sw() => tester.widget<Switch>(
        find.descendant(
          of: find.widgetWithText(SwitchListTile, 'Solo Wi-Fi'),
          matching: find.byType(Switch),
        ),
      );
      expect(sw().value, isTrue);
      await tester.tap(find.text('Solo Wi-Fi'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(sw().value, isFalse);
      expect(e.store.data[SyncPreferences.wifiOnlyKey], 'false');
      await tester.tap(find.text('Solo Wi-Fi'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(e.store.data[SyncPreferences.wifiOnlyKey], 'true');
    });

    testWidgets('cuota de Drive: barra usado/total', (tester) async {
      final e = await _open(tester);
      e.cloud.quotaValue = const CloudQuota(
        usedBytes: 5 * 1024 * mb,
        limitBytes: 15 * 1024 * mb,
      );
      await tester.runAsync(() => e.sync.refreshQuota());
      await tester.pumpAndSettle();
      expect(find.textContaining('5,00 GB de 15,00 GB usados'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('cerrar sesión: confirma, cierra y permite volver a iniciar', (
      tester,
    ) async {
      final e = await _open(tester);
      await tester.tap(find.text('Cerrar sesión de Google'));
      await tester.pumpAndSettle();
      expect(find.text('¿Cerrar sesión de Google?'), findsOneWidget);
      expect(find.textContaining('se conservan'), findsOneWidget);
      expect(find.textContaining('volver a iniciar sesión'), findsOneWidget);
      // Cancelar mantiene la sesión.
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(e.cloud.currentAccountEmail, isNotNull);

      await tester.tap(find.text('Cerrar sesión de Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(e.cloud.currentAccountEmail, isNull);
      expect(find.text('santy@example.com'), findsNothing);
      expect(find.textContaining('Sin cuenta conectada'), findsOneWidget);
      expect(find.text('Iniciar sesión con Google'), findsOneWidget);
      expect(find.text('Sincronizar ahora'), findsNothing);

      // Volver a iniciar sesión.
      await tester.tap(find.text('Iniciar sesión con Google'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(e.cloud.currentAccountEmail, isNotNull);
      expect(find.text(e.cloud.currentAccountEmail!), findsOneWidget);
    });

    testWidgets('error al iniciar sesión: muestra el mensaje', (tester) async {
      final e = await _open(tester);
      await e.sync.signOut();
      await tester.pumpAndSettle();
      e.cloud.failure = (op) => op == 'signin'
          ? const CloudSignInFailedException('Falló el inicio de sesión')
          : null;
      await tester.tap(find.text('Iniciar sesión con Google'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Falló el inicio de sesión'), findsOneWidget);
    });
  });

  testWidgets('el correo no se escribe en logs de depuración', (tester) async {
    final lines = <String?>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => lines.add(message);
    try {
      await _open(tester);
      await tester.tap(find.text('Cerrar sesión de Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    } finally {
      debugPrint = original;
    }
    expect(lines.whereType<String>().where((l) => l.contains('@')), isEmpty);
  });

  testWidgets('la bóveda muestra el engranaje y abre Ajustes', (tester) async {
    usePhoneSize(tester);
    final e = SettingsTestEnv();
    await tester.runAsync(e.init);
    addTearDown(e.dispose);
    await tester.pumpWidget(
      testApp(
        HomeVaultScreen(
          currentFolderName: 'Mi Bóveda',
          services: fakeServices(FakeVaultRepository(), sync: e.sync),
          settings: e.env,
          onLock: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.text('Seguridad'), findsOneWidget);
  });
}
