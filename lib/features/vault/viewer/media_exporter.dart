import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/session/session_ticket.dart';
import '../../../data/gallery/photo_saver.dart';
import '../../../data/models/vault_item_model.dart';
import '../models/browser_entry.dart';
import 'media_opener.dart';

enum ExportOutcome {
  saved,
  permissionDenied,
  failed,
  unsupported,
  cancelledByLock,
}

/// "Guardar en Fotos" (interfaz para el visor; la real es [VaultMediaExporter]).
abstract interface class MediaExporter {
  /// Solo fotos y videos se pueden guardar en la fototeca.
  static bool canExport(VaultItemModel item) {
    final k = fileKindOf(item);
    return k == FileKind.image || k == FileKind.video;
  }

  Future<ExportOutcome> export(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  });
}

/// Descifra el archivo a un temporal en claro, lo entrega
/// a la fototeca y BORRA el temporal en `finally`. Es la única vía por la que
/// el usuario saca una copia sin cifrar de la bóveda (diálogo previo en la UI).
class VaultMediaExporter implements MediaExporter {
  VaultMediaExporter({
    required this.opener,
    required this.saver,
    this.sessionTicket,
  });

  final VaultMediaOpener opener;
  final PhotoSaver saver;

  /// D67 (fase 8): ticket de la sesión de SU bóveda (o `null` si no está
  /// abierta). Se captura al empezar y se comprueba antes de escribir el
  /// temporal, en cada bloque y antes de entregar la copia a Fotos: tras un
  /// bloqueo (aunque se vuelva a abrir) nada sale de la bóveda. `null`
  /// (pruebas) = sin esta guarda.
  final SessionTicket? Function()? sessionTicket;

  @override
  Future<ExportOutcome> export(
    VaultItemModel item, {
    MediaProgressCallback? onProgress,
  }) async {
    if (!MediaExporter.canExport(item)) return ExportOutcome.unsupported;
    final isVideo = fileKindOf(item) == FileKind.video;
    final provider = sessionTicket;
    final SessionTicket? ticket = provider?.call();
    if (provider != null && ticket == null) {
      return ExportOutcome.cancelledByLock;
    }
    if (!await saver.requestAddPermission()) {
      return ExportOutcome.permissionDenied;
    }
    File? plain;
    try {
      ticket?.check();
      // D60: fila fresca (generación, ruta y fileId actuales).
      final fresh = await opener.fetcher.refresh(item);
      final gen = fresh.keyGen;
      final local = await opener.fetcher.ensureLocal(
        fresh,
        onProgress: (got, total) => onProgress?.call(
          MediaProgress(
            MediaPhase.downloading,
            total <= 0 ? null : got / total,
          ),
        ),
      );
      final key = opener.requireKey(gen);
      ticket?.check();
      final ext = p.extension(item.name);
      plain = opener.temp.newTempFile(
        extension: ext.isEmpty ? (isVideo ? '.mp4' : '.jpg') : ext,
      );
      final reader = await opener.crypto.openReader(
        local,
        key,
        expectedFileId: fresh.fileId,
      );
      RandomAccessFile? out;
      try {
        out = await plain.open(mode: FileMode.write);
        final total = reader.blockCount;
        for (var i = 0; i < total; i++) {
          // Si se bloquea durante la copia, requireKey() lanza y se aborta.
          opener.requireKey(gen);
          ticket?.check();
          await out.writeFrom(await reader.decryptBlock(i));
          onProgress?.call(
            MediaProgress(MediaPhase.decrypting, (i + 1) / total),
          );
        }
        await out.flush();
      } finally {
        await out?.close();
        await reader.close();
      }
      opener.requireKey(gen);
      ticket?.check();
      if (isVideo) {
        await saver.saveVideo(plain, filename: item.name);
      } else {
        await saver.saveImage(plain, filename: item.name);
      }
      return ExportOutcome.saved;
    } on StateError {
      return ExportOutcome.cancelledByLock;
    } on Object {
      return ExportOutcome.failed;
    } finally {
      if (plain != null) await opener.temp.release(plain);
    }
  }
}
