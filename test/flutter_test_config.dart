import 'dart:async';

import 'package:vault/core/services/app_paths.dart';

/// Configuración global de las pruebas. Muchas pruebas históricas usan ids
/// cortos (`i1`, `a`) en vez de UUID; S-15 hace estrictas las rutas de items
/// en producción, así que aquí se relaja SOLO para esas pruebas.
/// `test/s15_test.dart` lo desactiva para comprobar el comportamiento real.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppPaths.allowNonUuidIdsForTesting = true;
  await testMain();
}
