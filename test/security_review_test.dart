// Pruebas de regresión de la revisión de seguridad independiente
// (docs/REPORTE.md, sección "Revisión de seguridad independiente").
//
// S-01: autobloqueo anulado indefinidamente por AutoLockSuspension.
// S-02: copia EN CLARO del selector de archivos que nunca se borraba.
//
// Las pruebas no dependen de constantes nuevas (usan valores literales) para
// poder ejecutarse contra el código anterior y comprobar que fallan.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/security/auto_lock.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_residue.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/services/vault_import_service.dart';

class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

class _H {
  _H([AutoLockDelay delay = AutoLockDelay.seconds15]) {
    controller = AutoLockController(
      onLock: () => locks++,
      clock: AutoLockClock(monotonic: () => mono, wall: () => wall),
      suspension: suspension,
      timerFactory: (d, cb) {
        timerDuration = d;
        timerCb = cb;
        return _FakeTimer();
      },
      initialDelay: delay,
    );
  }

  Duration mono = Duration.zero;
  DateTime wall = DateTime.utc(2026, 1, 1);
  final suspension = AutoLockSuspension();
  late final AutoLockController controller;
  int locks = 0;
  Duration? timerDuration;
  void Function()? timerCb;

  void advance(Duration d) {
    mono += d;
    wall = wall.add(d);
  }

  void bg() {
    controller
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.hidden)
      ..didChangeAppLifecycleState(AppLifecycleState.paused);
  }

  void fg() {
    controller
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
  }
}

class _FailingCrypto extends CryptoService {
  @override
  Future<VaultHeader> encryptFile(
    File sourceFile,
    File destFile,
    SecretKey filesKey, {
    int blockSize = VaultHeader.defaultBlockSize,
  }) async => throw const FileSystemException('disco lleno');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S-01 autobloqueo con suspensión activa', () {
    test('HOME desde el selector y vuelta horas después: bloquea', () async {
      final h = _H();
      final gate = Completer<void>();
      final f = h.suspension.run(() async {
        h.bg(); // el selector pasa la app a segundo plano
        h.advance(const Duration(hours: 3)); // HOME desde el selector
        h.fg(); // vuelve con la suspensión AÚN activa
        await gate.future;
      });
      expect(h.locks, 1, reason: 'antes del arreglo: 0 (bóveda abierta)');
      gate.complete();
      await f;
    });

    test('dentro del tope (2 min) no bloquea', () async {
      final h = _H();
      final gate = Completer<void>();
      final f = h.suspension.run(() async {
        h.bg();
        h.advance(const Duration(minutes: 2));
        h.fg();
        await gate.future;
      });
      gate.complete();
      await f;
      expect(h.locks, 0);
    });

    test('temporizador del tope (5 min) en segundo plano: bloquea', () async {
      final h = _H();
      final gate = Completer<void>();
      final f = h.suspension.run(() async {
        h.bg();
        await gate.future;
      });
      expect(h.timerDuration, const Duration(minutes: 5));
      h.timerCb?.call();
      expect(h.locks, 1);
      gate.complete();
      await f;
    });

    test('la suspensión termina en segundo plano: se arma el normal', () async {
      // P. ej. la sincronización pide un token de Google justo al pulsar HOME.
      final h = _H();
      await h.suspension.run(() async => h.bg());
      expect(h.controller.isArmed, isTrue);
      expect(h.timerDuration, const Duration(seconds: 15));
      h.advance(const Duration(seconds: 15));
      h.fg();
      expect(h.locks, 1, reason: 'antes del arreglo: 0 (nunca se armaba)');
    });

    test('"inmediato" rearmado: margen de 3 s para volver', () async {
      final ok = _H(AutoLockDelay.immediate);
      await ok.suspension.run(() async => ok.bg());
      expect(ok.locks, 0, reason: 'el resultado del selector llega antes');
      expect(ok.timerDuration, const Duration(seconds: 3));
      ok.advance(const Duration(seconds: 1));
      ok.fg();
      expect(ok.locks, 0);

      final late = _H(AutoLockDelay.immediate);
      await late.suspension.run(() async => late.bg());
      late.advance(const Duration(seconds: 3));
      late.fg();
      expect(late.locks, 1);
    });

    test('lockNow y detach quitan el escuchador de la suspensión', () async {
      final h = _H();
      final gate = Completer<void>();
      final f = h.suspension.run(() async {
        h.bg();
        h.controller.lockNow();
        await gate.future;
      });
      expect(h.locks, 1);
      gate.complete();
      await f; // al terminar la suspensión no se rearma nada
      h.fg();
      expect(h.locks, 1);
    });
  });

  group('S-02 copia en claro del selector de archivos', () {
    late Directory tmp;
    late Directory pickerRoot;
    late VaultSession session;
    late VaultDatabase vdb;
    late VaultDataRepository repo;

    setUp(() async {
      sqfliteFfiInit();
      tmp = await Directory.systemTemp.createTemp('s02');
      await AppPaths.init(baseDir: Directory(p.join(tmp.path, 'app')));
      pickerRoot = Directory(p.join(tmp.path, 'cache', 'file_picker'))
        ..createSync(recursive: true);
      session = VaultSession.create()
        ..open(
          await KeyHierarchy.fromDek(
            Uint8List.fromList(List.generate(32, (i) => i + 7)),
          ),
        );
      vdb = VaultDatabase.forTesting(
        session: session,
        dbPath: p.join(tmp.path, 'app', 'db', 's02.db'),
        opener: (path, {password, required options}) =>
            databaseFactoryFfi.openDatabase(path, options: options),
      );
      repo = VaultDataRepository(dbProvider: () => vdb.database);
    });

    tearDown(() async {
      await vdb.close();
      AppPaths.resetForTesting();
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Windows puede retener el .db un instante.
      }
    });

    /// Lo que deja file_picker en Android: `<cache>/file_picker/<ms>/<nombre>`.
    File pickerCopy(String name) {
      final f = File(p.join(pickerRoot.path, '1731600000000', name))
        ..createSync(recursive: true)
        ..writeAsStringSync('declaracion de impuestos (en claro)');
      return f;
    }

    VaultImportService service(File picked, {CryptoService? crypto}) =>
        VaultImportService(
          pickFile: () async => (
            path: picked.path,
            name: p.basename(picked.path),
            size: picked.lengthSync(),
            extension: 'pdf',
          ),
          pickerCopyRoots: () async => [pickerRoot],
          filesKey: () => session.filesKey,
          crypto: crypto,
          repository: repo,
        );

    test('tras importar, la copia en claro ya no existe', () async {
      final copy = pickerCopy('Declaracion 2025.pdf');
      final ok = await service(copy).importAndEncryptFile(targetFolderId: null);
      expect(ok, isTrue);
      expect(copy.existsSync(), isFalse, reason: 'antes del arreglo quedaba');
      expect(copy.parent.existsSync(), isFalse, reason: 'carpeta <ms> vacía');
      expect(pickerRoot.existsSync(), isTrue, reason: 'la raíz no se borra');
      final items = await repo.getItemsByFolder(null);
      expect(items, hasLength(1));
      expect(AppPaths.resolve(items.single.encryptedPath).existsSync(), isTrue);
    });

    test('si el cifrado falla, la copia también se borra', () async {
      final copy = pickerCopy('Contrato.pdf');
      final ok = await service(
        copy,
        crypto: _FailingCrypto(),
      ).importAndEncryptFile(targetFolderId: null);
      expect(ok, isFalse);
      expect(copy.existsSync(), isFalse);
    });

    test(
      'un archivo FUERA de las carpetas del plugin nunca se borra',
      () async {
        final user = File(p.join(tmp.path, 'Documentos', 'original.pdf'))
          ..createSync(recursive: true)
          ..writeAsStringSync('original del usuario');
        final ok = await service(
          user,
        ).importAndEncryptFile(targetFolderId: null);
        expect(ok, isTrue);
        expect(user.existsSync(), isTrue);
        expect(
          PlainResidue.isWithinRoots(pickerRoot.path, [pickerRoot]),
          isFalse,
          reason: 'la raíz misma no cuenta como "dentro"',
        );
      },
    );

    test('barrido al arrancar: vacía las carpetas de restos', () async {
      pickerCopy('a.jpg');
      pickerCopy('b.mp4');
      final importTmp = PlainResidue.galleryImportTmp
        ..createSync(recursive: true);
      File(p.join(importTmp.path, 'x', 'video.mov'))
        ..createSync(recursive: true)
        ..writeAsStringSync('en claro');
      final n = await PlainResidue.sweepDirectories([pickerRoot, importTmp]);
      expect(n, 2);
      expect(pickerRoot.listSync(), isEmpty);
      expect(importTmp.listSync(), isEmpty);
    });
  });
}
