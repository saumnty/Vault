import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/key_hierarchy.dart';
import '../../core/crypto/vault_file_format.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../cloud/cloud_storage.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import '../sync/sync_service.dart' show md5OfFile;

/// Resultado del re-cifrado de un item.
enum ReencryptOutcome {
  /// Re-cifrado y fila cambiada a la generación nueva.
  done,

  /// La fila ya estaba en la generación nueva (reanudación).
  alreadyDone,

  /// La fila cambió entretanto (o se borró): no se tocó nada; se reintenta
  /// en la siguiente vuelta.
  changed,

  /// Ni la copia local ni la de Drive abren o coinciden (§9): el servicio
  /// pasa a `blockedCorrupt` y el usuario decide ("Omitir").
  corrupt,
}

class ReencryptResult {
  const ReencryptResult(
    this.outcome, {
    this.detail,
    this.md5,
    this.size,
    this.thumbLost = false,
    this.deferredDeletes = const [],
  });

  final ReencryptOutcome outcome;

  /// Motivo (sin datos del usuario) si [outcome] es `corrupt`.
  final String? detail;

  /// MD5 y tamaño del `.vault` NUEVO (la verificación de `uploading` los
  /// compara con Drive).
  final String? md5;
  final int? size;

  /// La miniatura no se pudo recuperar: el item queda sin miniatura (L5).
  final bool thumbLost;

  /// Rutas relativas de la generación vieja que NO se borraron porque el
  /// item estaba en uso (visor/streaming); se borran al liberarlo.
  final List<String> deferredDeletes;
}

/// Entrega el texto en claro de un `.vault` bloque a bloque (en MEMORIA,
/// nada en disco) para volver a cifrarlo, y calcula su SHA-256 al vuelo.
/// Pone a cero cada bloque descifrado cuando se consumió (mejor esfuerzo).
class DecryptingByteSource implements VaultByteSource {
  DecryptingByteSource(this._reader) : _sink = Sha256().newHashSink();

  final VaultFileReader _reader;
  final HashSink _sink;
  int _next = 0;
  Uint8List? _block;
  int _pos = 0;
  int bytes = 0;

  @override
  Future<Uint8List> read(int length) async {
    var block = _block;
    if (block == null || _pos >= block.length) {
      _wipe();
      if (_next >= _reader.blockCount) return Uint8List(0);
      block = _block = await _reader.decryptBlock(_next++);
      _pos = 0;
      _sink.add(block);
      if (block.isEmpty) return Uint8List(0);
    }
    final n = min(length, block.length - _pos);
    final out = Uint8List.fromList(
      Uint8List.sublistView(block, _pos, _pos + n),
    );
    _pos += n;
    bytes += n;
    return out;
  }

  /// SHA-256 (hex) del claro leído. Llamar una sola vez, al final.
  Future<String> hexDigest() async {
    _sink.close();
    return _hex((await _sink.hash()).bytes);
  }

  void _wipe() {
    final b = _block;
    if (b != null) b.fillRange(0, b.length, 0);
    _block = null;
  }

  void dispose() => _wipe();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Puntos internos del re-cifrado de un item (pruebas de cortes, §10.2-4).
enum ReencryptStep { afterSource, afterPart, afterRename, afterSwap }

class _SourceBad implements Exception {
  const _SourceBad(this.detail);
  final String detail;
}

/// Re-cifra UN item de la generación vieja a la nueva (§5).
///
/// 1. Fuente: el `.vault` local con el `fileId` registrado; si falta o no
///    autentica, la copia de Drive (tamaño + MD5 + `fileId`) bajada a
///    [workDir] (cifrada; no marca `en_cache`).
/// 2. Descifra bloque a bloque en memoria y cifra con la llave nueva y un
///    encabezado NUEVO (fileId aleatorio) a `vault/<id>.kN.vault.part`.
/// 3. SHA-256 del claro == `contentHash`; pasada completa de verificación
///    del archivo nuevo ([verifyFullPass]); MD5 del nuevo.
/// 4. Miniatura: descifrar con la vieja y cifrar con la nueva
///    (`thumbs/<id>.kN.thumb.part`); si no se puede, el item queda sin ella.
/// 5. `rename` de los `.part`.
/// 6. Transacción condicional ([VaultDataRepository.swapItemGeneration]).
///    Si la fila cambió, se borran los archivos nuevos.
/// 7. Se borran los archivos de la generación vieja (salvo en uso).
///
/// Nunca escribe texto en claro en disco. Los errores de red/nube se
/// propagan (el servicio pausa y reintenta); los `.part` se borran.
class ItemReencryptor {
  ItemReencryptor({
    required this.items,
    required this.cloud,
    required this.workDir,
    File Function(String relativePath)? resolvePath,
    CryptoService? crypto,
    this.isInUse,
    this.verifyFullPass = true,
    int Function()? nowMs,
    this.onStep,
  }) : _resolve = resolvePath ?? AppPaths.resolve,
       _crypto = crypto ?? CryptoService(),
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final VaultDataRepository items;
  final CloudStorage cloud;

  /// Carpeta de trabajo para fuentes bajadas de Drive (`vault_cache/rotation`).
  final Directory Function() workDir;
  final bool Function(String itemId)? isInUse;
  final bool verifyFullPass;

  /// Solo pruebas: se llama en cada [ReencryptStep] (puede lanzar para
  /// simular un corte).
  final void Function(ReencryptStep step)? onStep;
  final File Function(String) _resolve;
  final CryptoService _crypto;
  final int Function() _now;

  /// Tope de una miniatura descargada (S-14).
  static const int maxThumbBytes = 8 * 1024 * 1024;

  Future<ReencryptResult> reencrypt(
    VaultItemModel item, {
    required int fromGen,
    required KeyHierarchy from,
    required int toGen,
    required KeyHierarchy to,
    CloudCancelToken? cancel,
  }) async {
    final fresh = await items.getItem(item.id);
    if (fresh == null) return const ReencryptResult(ReencryptOutcome.changed);
    if (fresh.keyGen == toGen) {
      return const ReencryptResult(ReencryptOutcome.alreadyDone);
    }
    if (fresh.keyGen != fromGen) {
      return const ReencryptResult(ReencryptOutcome.changed);
    }

    final newRel = AppPaths.vaultRelativePath(fresh.id, gen: toGen);
    final newFile = _resolve(newRel);
    final newPart = File('${newFile.path}.part');
    final newThumbRel = AppPaths.thumbRelativePath(fresh.id, gen: toGen);
    final newThumb = _resolve(newThumbRel);
    final newThumbPart = File('${newThumb.path}.part');
    final download = File(p.join(workDir().path, '${fresh.id}.src.part'));
    var committed = false;
    try {
      for (final f in [newPart, newThumbPart, newFile, newThumb, download]) {
        if (f.existsSync()) await f.delete();
      }
      newFile.parent.createSync(recursive: true);
      newThumb.parent.createSync(recursive: true);

      // 1-3. Contenido.
      final String? digest;
      try {
        digest = await _reencryptContent(
          fresh,
          from: from,
          to: to,
          dest: newPart,
          download: download,
          cancel: cancel,
        );
      } on _SourceBad catch (e) {
        return ReencryptResult(ReencryptOutcome.corrupt, detail: e.detail);
      }
      if (digest == null) {
        return const ReencryptResult(
          ReencryptOutcome.corrupt,
          detail: 'sin copia que abra',
        );
      }
      final expected = fresh.contentHash?.toLowerCase();
      if (expected != null && expected != digest) {
        return const ReencryptResult(
          ReencryptOutcome.corrupt,
          detail: 'contentHash distinto',
        );
      }
      onStep?.call(ReencryptStep.afterPart);
      final newFileId = await CryptoService.fileIdOfFile(newPart);
      if (verifyFullPass) {
        final again = await _plainDigest(newPart, to.files, newFileId);
        if (again != digest) {
          return const ReencryptResult(
            ReencryptOutcome.corrupt,
            detail: 'verificación del archivo nuevo',
          );
        }
      }
      final size = await newPart.length();
      final md5 = await md5OfFile(newPart);

      // 4. Miniatura.
      String? thumbFileId;
      var thumbLost = false;
      if (fresh.thumbPath != null) {
        final plainThumb = await _oldThumbPlain(fresh, from);
        if (plainThumb == null) {
          thumbLost = true;
        } else {
          try {
            final enc = await _crypto.encryptBytes(plainThumb, to.thumbs);
            await newThumbPart.writeAsBytes(enc, flush: true);
            thumbFileId = CryptoService.fileIdOfHeader(enc);
          } finally {
            plainThumb.fillRange(0, plainThumb.length, 0);
          }
        }
      }

      // 5. Nombres definitivos (mismo directorio: atómico).
      await newPart.rename(newFile.path);
      if (thumbFileId != null) await newThumbPart.rename(newThumb.path);
      onStep?.call(ReencryptStep.afterRename);

      // 6. Fila (condicional) + cola.
      final ok = await items.swapItemGeneration(
        fresh.id,
        fromGen: fromGen,
        fromPath: fresh.encryptedPath,
        toGen: toGen,
        encryptedPath: newRel,
        fileId: newFileId,
        thumbPath: thumbFileId == null ? null : newThumbRel,
        thumbFileId: thumbFileId,
        nowMs: _now(),
      );
      if (!ok) {
        await _deleteQuietly(newFile);
        await _deleteQuietly(newThumb);
        return const ReencryptResult(ReencryptOutcome.changed);
      }
      committed = true;
      onStep?.call(ReencryptStep.afterSwap);

      // 7. Archivos de la generación vieja.
      final deferred = <String>[];
      final inUse = isInUse?.call(fresh.id) ?? false;
      final oldRels = [fresh.encryptedPath, ?fresh.thumbPath];
      for (final rel in oldRels) {
        if (rel == newRel || rel == newThumbRel) continue;
        if (inUse && rel == fresh.encryptedPath) {
          deferred.add(rel);
          continue;
        }
        await _deleteQuietly(_resolve(rel));
      }
      return ReencryptResult(
        ReencryptOutcome.done,
        md5: md5,
        size: size,
        thumbLost: thumbLost,
        deferredDeletes: deferred,
      );
    } finally {
      await _deleteQuietly(download);
      await _deleteQuietly(newPart);
      await _deleteQuietly(newThumbPart);
      if (!committed) {
        // Nada nuevo queda a medias si no se registró en la fila.
        VaultItemModel? row;
        try {
          row = await items.getItem(fresh.id);
        } on Object {
          row = null; // bloqueada: el barrido de la reanudación decide
        }
        if (row != null && row.encryptedPath != newRel) {
          await _deleteQuietly(newFile);
          await _deleteQuietly(newThumb);
        }
      }
    }
  }

  /// Re-cifra el contenido a [dest]. Devuelve el SHA-256 del claro, o
  /// `null` si no hay ninguna copia utilizable (ni local ni en Drive).
  Future<String?> _reencryptContent(
    VaultItemModel item, {
    required KeyHierarchy from,
    required KeyHierarchy to,
    required File dest,
    required File download,
    CloudCancelToken? cancel,
  }) async {
    final local = _resolve(item.encryptedPath);
    if (local.existsSync()) {
      try {
        return await _reencryptFrom(local, item, from, to, dest);
      } on VaultCryptoException {
        VaultLog.d('Rotación: copia local no abre', category: 'rotation');
      }
    }
    final driveId = item.driveFileId;
    if (driveId == null) return null;
    final CloudFile meta;
    try {
      meta = await cloud.getMetadata(driveId);
    } on CloudNotFoundException {
      return null;
    }
    download.parent.createSync(recursive: true);
    try {
      await cloud.download(driveId, download, cancel: cancel);
    } on CloudNotFoundException {
      return null;
    }
    final size = await download.length();
    final md5 = await md5OfFile(download);
    final wantSize = item.cloudSize ?? meta.size;
    final wantMd5 = (item.cloudMd5 ?? meta.md5Checksum)?.toLowerCase();
    if (size != wantSize || (wantMd5 != null && md5 != wantMd5)) {
      throw const _SourceBad('la copia de Drive no coincide');
    }
    try {
      return await _reencryptFrom(download, item, from, to, dest);
    } on VaultCryptoException {
      throw const _SourceBad('la copia de Drive no abre');
    }
  }

  Future<String> _reencryptFrom(
    File source,
    VaultItemModel item,
    KeyHierarchy from,
    KeyHierarchy to,
    File dest,
  ) async {
    final reader = await _crypto.openReader(
      source,
      from.files,
      expectedFileId: item.fileId,
    );
    final src = DecryptingByteSource(reader);
    try {
      onStep?.call(ReencryptStep.afterSource);
      await _crypto.encryptSource(
        src,
        dest,
        to.files,
        blockSize: reader.blockSize,
      );
      return await src.hexDigest();
    } catch (_) {
      await _deleteQuietly(dest);
      rethrow;
    } finally {
      src.dispose();
      await reader.close();
    }
  }

  Future<String> _plainDigest(File file, SecretKey key, String fileId) async {
    final reader = await _crypto.openReader(file, key, expectedFileId: fileId);
    final sink = Sha256().newHashSink();
    try {
      for (var i = 0; i < reader.blockCount; i++) {
        final block = await reader.decryptBlock(i);
        sink.add(block);
        block.fillRange(0, block.length, 0);
      }
    } finally {
      await reader.close();
    }
    sink.close();
    return _hex((await sink.hash()).bytes);
  }

  /// Miniatura vieja en claro (en memoria), local o de Drive; `null` si no
  /// hay ninguna que abra.
  Future<Uint8List?> _oldThumbPlain(
    VaultItemModel item,
    KeyHierarchy from,
  ) async {
    final local = _resolve(item.thumbPath!);
    if (local.existsSync()) {
      try {
        return await _crypto.decryptBytes(
          await local.readAsBytes(),
          from.thumbs,
          expectedFileId: item.thumbFileId,
        );
      } on VaultCryptoException {
        // se prueba Drive
      }
    }
    final id = item.thumbDriveFileId;
    if (id == null) return null;
    final Uint8List bytes;
    try {
      bytes = await cloud.downloadBytes(id, maxBytes: maxThumbBytes);
    } on CloudNotFoundException {
      return null;
    } on CloudTooLargeException {
      return null;
    }
    try {
      return await _crypto.decryptBytes(
        bytes,
        from.thumbs,
        expectedFileId: item.thumbFileId,
      );
    } on VaultCryptoException {
      VaultLog.d('Rotación: miniatura de Drive no abre', category: 'rotation');
      return null;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // se barre al reanudar
    }
  }
}
