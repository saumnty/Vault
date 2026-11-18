import '../logging/diagnostics_buffer.dart';
import '../services/plain_temp_manager.dart';
import '../streaming/vault_stream_server.dart';
import 'image_cache_wipe.dart';
import 'vault_session.dart';

/// Ganchos de seguridad COMUNES al bloquear, sea cual sea la bóveda abierta
/// (D67, M1 de la revisión de la fase 8). Antes vivían en `VaultServices`
/// (`_createCore` / `_createThumbs`); si la bóveda secundaria se abriera sin
/// crear esos servicios, al bloquear no se borrarían sus temporales en claro
/// (G5). Ahora se instalan una sola vez por sesión, independientes de ellos:
///
/// * temporales DESCIFRADOS de `tmp_plain/` de TODAS las bóvedas
///   (`PlainTempManager.instance.purgeSync`);
/// * todo servidor de streaming loopback (`VaultStreamServer.closeAllNow`);
/// * el registro de diagnóstico en memoria (`DiagnosticsBuffer.clear`);
/// * la caché global de imágenes decodificadas (S-05, `wipeImageCache`).
abstract final class SessionHooks {
  static final Expando<bool> _installed = Expando('SessionHooks');

  /// Instala los ganchos en [session] (por defecto la de la app). Idempotente.
  static void ensureInstalled([VaultSession? session]) {
    final s = session ?? VaultSession();
    if (_installed[s] == true) return;
    _installed[s] = true;
    s.addOnClear(DiagnosticsBuffer.instance.clear);
    s.addOnClear(PlainTempManager.instance.purgeSync);
    s.addOnClear(VaultStreamServer.closeAllNow);
    s.addOnClear(wipeImageCache);
  }

  /// `true` si ya están instalados en [session].
  static bool isInstalled([VaultSession? session]) =>
      _installed[session ?? VaultSession()] == true;
}
