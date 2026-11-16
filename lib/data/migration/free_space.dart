import 'dart:io';

import 'package:flutter/services.dart';

/// Espacio libre (bytes) del almacenamiento de la app, o `null` si no se
/// puede saber. Nunca lanza.
typedef FreeSpaceProvider = Future<int?> Function();

/// Canal `vault/security`, método `freeSpace` (Android: StatFs; iOS:
/// `volumeAvailableCapacityForImportantUsage`, // iOS: sin probar).
Future<int?> platformFreeSpace({
  MethodChannel? channel,
  bool? supported,
}) async {
  if (!(supported ?? (Platform.isAndroid || Platform.isIOS))) return null;
  try {
    final v = await (channel ?? const MethodChannel('vault/security'))
        .invokeMethod<num>('freeSpace')
        .timeout(const Duration(seconds: 5));
    return v?.toInt();
  } on Object {
    return null;
  }
}
