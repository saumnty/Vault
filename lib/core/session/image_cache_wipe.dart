import 'package:flutter/painting.dart';

/// S-05: vacía la caché global de imágenes de Flutter (imágenes ya
/// decodificadas de miniaturas y fotos) y suelta las imágenes "vivas". Se
/// engancha a `VaultSession.addOnClear` para que, tras bloquear, un volcado
/// de memoria no recupere fotos descifradas. No lanza si el binding de
/// Flutter no está inicializado (pruebas de lógica pura).
void wipeImageCache() {
  try {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  } on Object {
    // Sin binding: no hay caché que vaciar.
  }
}

/// Sobrescribe con ceros [bytes] (buffers propios en claro). Solo debe
/// llamarse cuando ningún `ImageProvider` activo los va a volver a leer.
void zeroFill(List<int>? bytes) {
  if (bytes == null) return;
  bytes.fillRange(0, bytes.length, 0);
}
