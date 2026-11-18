import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/security/platform_security.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_residue.dart';
import 'package:vault/core/services/plain_temp_manager.dart';

/// Fase 8 (G1, M2): sin bóveda secundaria, los barridos y la exclusión de
/// iCloud no crean ni tocan `alt/`; con ella, la barren sin crear nada más.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory base;
  final calls = <MethodCall>[];
  const channel = MethodChannel('vault/security');

  setUp(() async {
    base = await Directory.systemTemp.createTemp('g1_alt');
    await AppPaths.init(baseDir: base);
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
          calls.add(c);
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppPaths.resetForTesting();
    if (base.existsSync()) await base.delete(recursive: true);
  });

  List<String> listing() => [
    for (final e in base.listSync(recursive: true))
      p.relative(e.path, from: base.path).replaceAll('\\', '/'),
  ]..sort();

  Future<void> startupLike() async {
    await AppPaths.init();
    await PlainTempManager.instance.sweepAll();
    await PlainResidue.sweepAtStartup();
    await PlatformSecurity(
      isAndroid: false,
      isIOS: true,
    ).excludeVaultFromBackup();
    PlainTempManager.instance.purgeSync(); // como al bloquear
  }

  test('N arranques y bloqueos sin secundaria: no aparece alt/', () async {
    await startupLike();
    final before = listing();
    for (var i = 0; i < 3; i++) {
      await startupLike();
    }
    expect(listing(), before);
    expect(VaultPaths.secondary.exists, isFalse);
    expect(before.any((e) => e == 'alt' || e.startsWith('alt/')), isFalse);
    // La exclusión de iCloud pide exactamente las 4 carpetas de siempre.
    for (final c in calls) {
      expect((c.arguments as Map)['paths'], PlatformSecurity.vaultPaths());
    }
  });

  test('con alt/ existente: se excluye de iCloud y se barren sus temporales '
      'en claro y de importación, sin crear nada más', () async {
    final alt = VaultPaths.secondary;
    alt.tmpPlainDir.createSync(recursive: true);
    alt.importTmpDir.createSync(recursive: true);
    File(p.join(alt.tmpPlainDir.path, 'p1.mp4')).writeAsStringSync('claro');
    File(p.join(alt.importTmpDir.path, 'x.jpg')).writeAsStringSync('claro');
    // Un archivo cifrado de la secundaria NO se toca.
    alt.vaultDir.createSync(recursive: true);
    final kept = File(p.join(alt.vaultDir.path, 'k.vault'))
      ..writeAsStringSync('cifrado');

    await PlainTempManager.instance.sweepAll();
    expect(alt.tmpPlainDir.listSync(), isEmpty);
    await PlainResidue.sweepAtStartup();
    expect(alt.importTmpDir.listSync(), isEmpty);
    expect(kept.existsSync(), isTrue);

    await PlatformSecurity(
      isAndroid: false,
      isIOS: true,
    ).excludeVaultFromBackup();
    final paths = (calls.single.arguments as Map)['paths'] as List;
    expect(paths, [...PlatformSecurity.vaultPaths(), alt.root.path]);
    // No se crearon carpetas de la secundaria que no existieran.
    expect(alt.thumbsDir.existsSync(), isFalse);
    expect(alt.dbDir.existsSync(), isFalse);
  });

  test('al bloquear (purgeSync) se borran los temporales en claro de las dos '
      'bóvedas', () async {
    final alt = VaultPaths.secondary;
    alt.tmpPlainDir.createSync(recursive: true);
    AppPaths.tmpPlainDir.createSync(recursive: true);
    File(p.join(alt.tmpPlainDir.path, 'a.mp4')).writeAsStringSync('claro');
    File(p.join(AppPaths.tmpPlainDir.path, 'b.mp4')).writeAsStringSync('claro');
    PlainTempManager.instance.purgeSync();
    expect(alt.tmpPlainDir.listSync(), isEmpty);
    expect(AppPaths.tmpPlainDir.listSync(), isEmpty);
  });

  test('un PlainTempManager con carpeta propia no barre otras', () async {
    final own = Directory(p.join(base.path, 'own'))..createSync();
    final other = VaultPaths.secondary.tmpPlainDir..createSync(recursive: true);
    File(p.join(other.path, 'x')).writeAsStringSync('x');
    final m = PlainTempManager(dirProvider: () => own);
    m.purgeSync();
    await m.sweepAll();
    expect(other.listSync(), hasLength(1));
  });
}
