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

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/security/auto_lock.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_residue.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/picker/document_picker.dart';
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
  Future<VaultHeader> encryptSource(
    VaultByteSource source,
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

  group('S-02 (cerrado en v2 fase 6): selector propio sin copia en claro', () {
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

    VaultImportService service(_FakeDoc? doc, {CryptoService? crypto}) =>
        VaultImportService(
          picker: _FakePicker(doc),
          filesKey: () => session.filesKey,
          crypto: crypto,
          repository: repo,
        );

    List<FileSystemEntity> residue() => [
      ...pickerRoot.listSync(recursive: true),
      ...AppPaths.tmpPlainDir.existsSync()
          ? AppPaths.tmpPlainDir.listSync(recursive: true)
          : <FileSystemEntity>[],
    ];

    test(
      'importa leyendo del proveedor: cifra, hash, tamaño y SIN copias',
      () async {
        final data = Uint8List.fromList(
          List.generate(2 * 1024 * 1024 + 321, (i) => (i * 7) & 0xff),
        );
        final doc = _FakeDoc('Declaracion 2025.pdf', data, chunk: 300000);
        final ok = await service(
          doc,
        ).importAndEncryptFile(targetFolderId: null);
        expect(ok, isTrue);
        expect(doc.closed, isTrue);
        expect(residue(), isEmpty);
        final item = (await repo.getItemsByFolder(null)).single;
        expect(item.fileSize, data.length);
        expect(item.name, 'Declaracion 2025.pdf');
        expect(item.mimeType, 'pdf');
        expect(
          item.contentHash,
          crypto.sha256.convert(data).toString(),
          reason: 'SHA-256 del contenido original',
        );
        // El .vault descifra a los bytes originales.
        final plain = await CryptoService().decryptBytes(
          await AppPaths.resolve(item.encryptedPath).readAsBytes(),
          session.filesKey!,
        );
        expect(plain, data);
      },
    );

    test('archivo vacío y exacto al tamaño de bloque', () async {
      for (final n in [0, 1024 * 1024]) {
        final ok = await service(
          _FakeDoc('x$n.bin', Uint8List(n)),
        ).importAndEncryptFile(targetFolderId: null);
        expect(ok, isTrue, reason: 'n=$n');
      }
      final items = await repo.getItemsByFolder(null);
      expect(items.map((i) => i.fileSize).toSet(), {0, 1024 * 1024});
    });

    test('cancelar el selector: no importa nada', () async {
      expect(
        await service(null).importAndEncryptFile(targetFolderId: null),
        isFalse,
      );
      expect(await repo.getItemsByFolder(null), isEmpty);
    });

    test(
      'si la lectura falla: false, flujo cerrado, sin .vault parcial',
      () async {
        final doc = _FakeDoc('c.pdf', Uint8List(3 * 1024 * 1024), failAfter: 1);
        final ok = await service(
          doc,
        ).importAndEncryptFile(targetFolderId: null);
        expect(ok, isFalse);
        expect(doc.closed, isTrue);
        expect(AppPaths.vaultDir.listSync(), isEmpty);
        expect(await repo.getItemsByFolder(null), isEmpty);
      },
    );

    test('si el cifrado falla: el flujo también se cierra', () async {
      final doc = _FakeDoc('d.pdf', Uint8List(100));
      final ok = await service(
        doc,
        crypto: _FailingCrypto(),
      ).importAndEncryptFile(targetFolderId: null);
      expect(ok, isFalse);
      expect(doc.closed, isTrue);
    });

    test('bóveda bloqueada: no abre el selector', () async {
      final picker = _FakePicker(_FakeDoc('e.pdf', Uint8List(10)));
      final ok = await VaultImportService(
        picker: picker,
        filesKey: () => null,
        repository: repo,
      ).importAndEncryptFile(targetFolderId: null);
      expect(ok, isFalse);
      expect(picker.opened, 0);
    });

    test('barrido al arrancar: restos de versiones anteriores', () async {
      File(p.join(pickerRoot.path, '1731600000000', 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('en claro');
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

class _FakeDoc implements PickedDocument {
  _FakeDoc(this.name, this.data, {this.chunk = 1 << 20, this.failAfter});

  final Uint8List data;
  final int chunk;
  final int? failAfter;
  int _pos = 0;
  int _reads = 0;
  bool closed = false;

  @override
  final String name;

  @override
  int? get size => data.length;

  @override
  String? get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? null : name.substring(dot + 1).toLowerCase();
  }

  @override
  Future<Uint8List> read(int length) async {
    if (failAfter != null && _reads++ >= failAfter!) {
      throw const FileSystemException('lectura');
    }
    final n = [
      length,
      chunk,
      data.length - _pos,
    ].reduce((a, b) => a < b ? a : b);
    final out = Uint8List.sublistView(data, _pos, _pos + n);
    _pos += n;
    return Uint8List.fromList(out);
  }

  @override
  Future<void> close() async => closed = true;
}

class _FakePicker implements DocumentPicker {
  _FakePicker(this.doc);
  final _FakeDoc? doc;
  int opened = 0;

  @override
  Future<PickedDocument?> pick() async {
    opened++;
    return doc;
  }
}
