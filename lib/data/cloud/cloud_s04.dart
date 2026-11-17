import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'cloud_storage.dart';

/// La copia subida no coincide con lo enviado (tamaño o MD5).
class CloudUploadMismatchException implements Exception {
  const CloudUploadMismatchException(this.detail);
  final String detail;
  @override
  String toString() => 'CloudUploadMismatchException: $detail';
}

/// Patrón S-04 (D42) para material de llaves en Drive: NUNCA `files.update`
/// (Drive guardaría el contenido anterior como revisión durante ~30 días).
///
/// 1. Se listan los archivos que ya tienen [name].
/// 2. Se CREA un archivo nuevo con [bytes] y se verifica tamaño + MD5.
/// 3. Solo entonces se BORRAN (permanente, con sus revisiones) todos los
///    anteriores con ese nombre.
///
/// Si la verificación falla, el archivo recién creado se borra y lo anterior
/// queda intacto ([CloudUploadMismatchException]). Si el borrado de lo
/// anterior falla, se propaga el error: el llamador reintenta y la siguiente
/// pasada vuelve a crear y a borrar todo lo previo. Devuelve el archivo
/// nuevo.
Future<CloudFile> uploadBytesReplacingByName(
  CloudStorage cloud, {
  required String name,
  required Uint8List bytes,
}) async {
  final previous = [
    for (final f in await cloud.list())
      if (f.name == name) f.id,
  ];
  final remote = await cloud.uploadBytes(bytes: bytes, name: name);
  final md5 = crypto.md5.convert(bytes).toString();
  if (remote.size != bytes.length || remote.md5Checksum?.toLowerCase() != md5) {
    try {
      await cloud.delete(remote.id);
    } on CloudNotFoundException {
      // ya no está
    }
    throw CloudUploadMismatchException(
      remote.size != bytes.length ? 'tamaño' : 'MD5',
    );
  }
  for (final id in previous) {
    if (id == remote.id) continue;
    try {
      await cloud.delete(id);
    } on CloudNotFoundException {
      // ya no existe
    }
  }
  return remote;
}
