import 'dart:async';

import '../../core/logging/vault_log.dart';
import 'cloud_storage.dart';

/// D78 (parte B, §B.4): inicio de sesión interactivo con PLAZO y con salida.
///
/// [hipótesis del iPhone] Si el `Future` del selector de Google nunca
/// completa (selector descartado por el sistema, presentación fallida), el
/// llamador quedaba colgado para siempre (p. ej. `_running` de la migración).
/// Aquí:
/// * pasado [timeout] se libera la espera con
///   [CloudSignInTimeoutException];
/// * [abandon] libera la espera en el acto (botón «Pausar»/«Detener») con
///   [CloudSignInCancelledException];
/// * un resultado que llegue DESPUÉS se ignora (solo se registra). La sesión
///   que pudiera dejar no se cierra aquí: podría ser la de un intento más
///   nuevo; quien vuelva a correr mira la sesión actual como siempre.
///
/// Registra (sin datos: ni correo ni id) selector abierto / cancelado /
/// fallido (tipo) / sin respuesta / inicio de sesión correcto.
class GuardedSignIn {
  GuardedSignIn({this.timeout = defaultTimeout});

  /// Plazo por defecto: deja tiempo para elegir cuenta y pasar la
  /// verificación en dos pasos, por debajo del tope de 5 min de la
  /// suspensión del autobloqueo.
  static const Duration defaultTimeout = Duration(minutes: 3);

  final Duration timeout;
  Completer<CloudAccount>? _pending;

  /// `true` mientras hay un selector abierto (esperando).
  bool get inProgress => _pending != null;

  Future<CloudAccount> signIn(CloudStorage cloud, {String category = 'auth'}) {
    final c = Completer<CloudAccount>();
    _pending = c;
    VaultLog.d('Selector de Google abierto', category: category);
    final timer = Timer(timeout, () {
      if (c.isCompleted) return;
      VaultLog.e('Selector de Google sin respuesta', null, category);
      c.completeError(const CloudSignInTimeoutException());
    });
    Future<CloudAccount> attempt;
    try {
      attempt = cloud.signIn();
    } on Object catch (e, st) {
      attempt = Future.error(e, st);
    }
    attempt.then(
      (account) {
        if (c.isCompleted) {
          VaultLog.d(
            'Selector de Google respondió tarde: se ignora',
            category: category,
          );
          return;
        }
        VaultLog.d('Sesión de Google iniciada', category: category);
        c.complete(account);
      },
      onError: (Object e, StackTrace st) {
        if (c.isCompleted) return;
        if (e is CloudSignInCancelledException) {
          VaultLog.d('Selector de Google cancelado', category: category);
        } else {
          VaultLog.e('Selector de Google falló', e, category);
        }
        c.completeError(e, st);
      },
    );
    return c.future.whenComplete(() {
      timer.cancel();
      if (identical(_pending, c)) _pending = null;
    });
  }

  /// Libera la espera del selector abierto (si lo hay).
  void abandon({String category = 'auth'}) {
    final c = _pending;
    if (c == null || c.isCompleted) return;
    VaultLog.d('Selector de Google abandonado', category: category);
    c.completeError(const CloudSignInCancelledException());
  }
}
