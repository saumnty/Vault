// S-17: las llaves no sobreviven más de la ventana acotada al bloquear.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/security/lock_flush.dart';

void main() {
  test('la ventana por defecto es de 1 s como máximo', () {
    expect(kLockFlushBudget <= const Duration(seconds: 1), isTrue);
  });

  test('sin flush bloquea al instante', () {
    var n = 0;
    lockWithFlush(flush: null, lock: () => n++);
    expect(n, 1);
  });

  test('flush colgado: bloquea al agotarse la ventana, una sola vez', () {
    fakeAsync((fa) {
      var n = 0;
      final never = Completer<void>();
      lockWithFlush(flush: () => never.future, lock: () => n++);
      fa.elapse(kLockFlushBudget - const Duration(milliseconds: 1));
      expect(n, 0);
      fa.elapse(const Duration(milliseconds: 2));
      expect(n, 1);
      never.complete(); // un flush tardío no vuelve a bloquear
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 10));
      expect(n, 1);
    });
  });

  test('flush rápido: bloquea al terminar, sin esperar la ventana', () {
    fakeAsync((fa) {
      var n = 0;
      lockWithFlush(
        flush: () => Future<void>.delayed(const Duration(milliseconds: 50)),
        lock: () => n++,
      );
      fa.elapse(const Duration(milliseconds: 60));
      expect(n, 1);
      fa.elapse(const Duration(seconds: 5));
      expect(n, 1);
    });
  });

  test('flush que falla: bloquea igual', () {
    fakeAsync((fa) {
      var n = 0;
      lockWithFlush(flush: () async => throw StateError('x'), lock: () => n++);
      fa.flushMicrotasks();
      expect(n, 1);
    });
  });
}
