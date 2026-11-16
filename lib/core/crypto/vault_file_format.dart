import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'aes_gcm_backend.dart';

// =============================================================================
// FORMATO .vault VERSIÓN 2
// =============================================================================
//
// Todos los enteros son little-endian.
//
// ENCABEZADO (24 bytes, [VaultHeader.length])
//   off  len  campo
//   0    3    magic = "VLT" (0x56 0x4C 0x54)
//   3    1    versión = 0x02
//   4    16   fileId: UUID v4 aleatorio (122 bits de Random.secure)
//   20   4    blockSize (uint32): bytes de texto plano por bloque completo.
//             Por defecto 1 MiB. Rango aceptado [minBlockSize, maxBlockSize].
//
// BLOQUES (a continuación del encabezado, uno tras otro, sin separadores)
//   off  len  campo
//   0    12   nonce (aleatorio, Random.secure, distinto por bloque)
//   12   m    ciphertext AES-256-GCM (m = longitud del texto plano del bloque)
//   12+m 16   tag GCM
//   → sobrecarga fija de [blockOverhead] = 28 bytes por bloque.
//
// AAD de cada bloque (33 bytes):
//   encabezado completo (24) ‖ índice del bloque (uint64) ‖ isFinal (1 byte: 0/1)
//
// REGLA DEL BLOQUE FINAL
//   * Todos los bloques salvo el último llevan exactamente blockSize bytes de
//     texto plano. El último lleva los bytes restantes: 1..blockSize.
//   * Un archivo de 0 bytes es un único bloque final vacío (28 bytes).
//   * Nunca existe un bloque final vacío salvo en el archivo vacío. Un
//     archivo de exactamente N*blockSize bytes termina en un bloque final
//     COMPLETO (no se añade un bloque vacío).
//   * Por eso el número de bloques y cuál es el final se deducen sin
//     ambigüedad de la longitud física L del archivo (ver [VaultLayout]):
//       D = L − 24,  E = blockSize + 28
//       r = D mod E;  n = D div E  (+1 si r ≠ 0)
//       r == 0          → último bloque completo
//       1 ≤ r < 28      → formato inválido (truncado a mitad de bloque)
//       r == 28 y n > 1 → formato inválido (bloque final vacío)
//     El bloque n−1 se descifra con isFinal=1 y el resto con isFinal=0.
//
// QUÉ DETECTA (VaultAuthException salvo que se indique)
//   * Bloque alterado (o encabezado alterado): falla el tag GCM.
//   * Bloques reordenados: el índice forma parte de la AAD.
//   * Truncado quitando bloques completos: el nuevo último bloque fue cifrado
//     con isFinal=0 y el lector lo verifica con isFinal=1.
//   * Truncado/añadido a mitad de bloque: longitud imposible
//     (VaultFormatException) o tag inválido en el último bloque.
//   * Bloque copiado de otro archivo (misma llave): el fileId del encabezado
//     forma parte de la AAD, así que no verifica en un archivo con otro fileId.
//   * Encabezado con magic/versión/tamaño de bloque inválidos:
//     VaultFormatException antes de descifrar nada.
//
// DECISIÓN SOBRE EL NONCE: aleatorio por bloque y guardado en el bloque.
//   * La llave es directamente la subllave HKDF "files" (o "thumbs"), común
//     a TODOS los archivos. Un nonce derivado (p. ej. prefijo(fileId) ‖
//     contador) obligaría a truncar el fileId a ≤ 64 bits dentro de 96 y la
//     unicidad entre archivos dependería de que esos prefijos no colisionen;
//     un error de implementación (o reutilizar un fileId) repetiría nonces
//     con la misma llave, lo que en GCM es catastrófico.
//   * Con 96 bits aleatorios por bloque, NIST SP 800-38D §8.3 permite hasta
//     2^32 invocaciones por llave con probabilidad de colisión < 2^-32; con
//     bloques de 1 MiB eso son ~4 PiB por llave, muy por encima del uso real.
//   * Coste: 12 bytes por MiB (0,001 %). Sin estado que mantener.
//
// ACCESO ALEATORIO
//   Como blockSize es fijo, el bloque i empieza en 24 + i·(blockSize+28) y el
//   texto plano en el offset p está en el bloque p div blockSize. El tamaño
//   total en claro es (n−1)·blockSize + último. Ver [VaultFileReader].
//   La longitud física no está autenticada por sí misma: se autentica al
//   verificar el bloque final (su índice e isFinal fijan n, y los demás
//   bloques tienen tamaño fijo). [VaultFileReader.open] lo hace por defecto.
// =============================================================================

/// Error de criptografía/formato de un `.vault`.
sealed class VaultCryptoException implements Exception {
  const VaultCryptoException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Estructura inválida: magic, versión, tamaño de bloque o longitud imposible.
/// Se detecta sin la llave.
class VaultFormatException extends VaultCryptoException {
  const VaultFormatException(super.message);
}

/// Falló la autenticación AES-GCM de un bloque: llave incorrecta, bloque
/// alterado, reordenado, truncado o procedente de otro archivo. (Por diseño
/// de GCM no se puede distinguir cuál de ellas.)
class VaultAuthException extends VaultCryptoException {
  const VaultAuthException(super.message, {this.blockIndex});
  final int? blockIndex;
}

/// S-09: el `.vault` (o `.thumb`) es auténtico pero NO es el que la base de
/// datos registró para ese item (intercambio de archivos, índice antiguo). Se
/// trata como archivo dañado.
class VaultFileMismatchException extends VaultCryptoException {
  const VaultFileMismatchException()
    : super('El archivo no corresponde a este elemento (fileId distinto)');
}

// -----------------------------------------------------------------------------
// Encabezado
// -----------------------------------------------------------------------------

class VaultHeader {
  VaultHeader._(this.bytes);

  static const List<int> magic = [0x56, 0x4C, 0x54]; // "VLT"
  static const int version = 0x02;
  static const int length = 24;
  static const int fileIdLength = 16;

  static const int defaultBlockSize = 1024 * 1024; // 1 MiB
  static const int minBlockSize = 1024; // 1 KiB
  static const int maxBlockSize = 16 * 1024 * 1024; // 16 MiB (tope de RAM)

  /// Los 24 bytes tal cual van en el archivo (y en la AAD).
  final Uint8List bytes;

  Uint8List get fileId =>
      Uint8List.fromList(bytes.sublist(4, 4 + fileIdLength));

  int get blockSize => ByteData.sublistView(bytes).getUint32(20, Endian.little);

  /// fileId en forma canónica de UUID (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx).
  String get fileIdString {
    final h = fileId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// Encabezado nuevo con un fileId aleatorio.
  factory VaultHeader.generate({
    int blockSize = defaultBlockSize,
    Random? random,
  }) {
    _checkBlockSize(blockSize, isArgument: true);
    final rng = random ?? Random.secure();
    final b = Uint8List(length);
    b.setRange(0, 3, magic);
    b[3] = version;
    for (var i = 0; i < fileIdLength; i++) {
      b[4 + i] = rng.nextInt(256);
    }
    // UUID v4 (RFC 9562): versión 4 y variante 10xx.
    b[4 + 6] = (b[4 + 6] & 0x0F) | 0x40;
    b[4 + 8] = (b[4 + 8] & 0x3F) | 0x80;
    ByteData.sublistView(b).setUint32(20, blockSize, Endian.little);
    return VaultHeader._(b);
  }

  /// Valida y copia un encabezado leído del archivo. No lo autentica: eso
  /// ocurre al verificar cualquier bloque (el encabezado está en la AAD).
  factory VaultHeader.parse(List<int> raw) {
    if (raw.length < length) {
      throw const VaultFormatException(
        'Archivo demasiado corto para un encabezado .vault',
      );
    }
    if (raw[0] != magic[0] || raw[1] != magic[1] || raw[2] != magic[2]) {
      throw const VaultFormatException('No es un archivo .vault (magic)');
    }
    if (raw[3] != version) {
      throw VaultFormatException(
        'Versión .vault no soportada: ${raw[3]} (se esperaba $version)',
      );
    }
    final h = VaultHeader._(Uint8List.fromList(raw.sublist(0, length)));
    _checkBlockSize(h.blockSize, isArgument: false);
    return h;
  }

  static void _checkBlockSize(int size, {required bool isArgument}) {
    if (size >= minBlockSize && size <= maxBlockSize) return;
    final msg =
        'Tamaño de bloque fuera de rango: $size '
        '(permitido $minBlockSize..$maxBlockSize)';
    if (isArgument) throw ArgumentError(msg);
    throw VaultFormatException(msg);
  }
}

// -----------------------------------------------------------------------------
// Geometría del archivo
// -----------------------------------------------------------------------------

/// Posición y tamaño de cada bloque, deducidos de blockSize y la longitud
/// física del archivo cifrado.
class VaultLayout {
  VaultLayout._(this.blockSize, this.blockCount, this.plaintextLength);

  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int blockOverhead = nonceLength + tagLength; // 28

  final int blockSize;
  final int blockCount;
  final int plaintextLength;

  int get encryptedLength =>
      VaultHeader.length + blockCount * blockOverhead + plaintextLength;

  /// Geometría para cifrar [plaintextLength] bytes.
  factory VaultLayout.forPlaintext(int plaintextLength, int blockSize) {
    if (plaintextLength < 0) throw ArgumentError.value(plaintextLength);
    final n = plaintextLength == 0
        ? 1
        : (plaintextLength + blockSize - 1) ~/ blockSize;
    return VaultLayout._(blockSize, n, plaintextLength);
  }

  /// Geometría a partir de la longitud física (ver reglas arriba).
  factory VaultLayout.fromEncryptedLength(int encryptedLength, int blockSize) {
    final d = encryptedLength - VaultHeader.length;
    if (d < blockOverhead) {
      throw const VaultFormatException(
        'Archivo truncado: no contiene ningún bloque completo',
      );
    }
    final e = blockSize + blockOverhead;
    final full = d ~/ e;
    final r = d % e;
    final int n;
    final int lastPlain;
    if (r == 0) {
      n = full;
      lastPlain = blockSize;
    } else {
      n = full + 1;
      if (r < blockOverhead) {
        throw const VaultFormatException(
          'Longitud inválida: archivo truncado a mitad de bloque',
        );
      }
      lastPlain = r - blockOverhead;
      if (lastPlain == 0 && n > 1) {
        throw const VaultFormatException(
          'Longitud inválida: bloque final vacío en archivo no vacío',
        );
      }
    }
    return VaultLayout._(blockSize, n, (n - 1) * blockSize + lastPlain);
  }

  bool isFinal(int index) => index == blockCount - 1;

  int plainBlockLength(int index) {
    _checkIndex(index);
    return isFinal(index)
        ? plaintextLength - (blockCount - 1) * blockSize
        : blockSize;
  }

  int encryptedBlockLength(int index) =>
      plainBlockLength(index) + blockOverhead;

  /// Offset del bloque [index] dentro del archivo cifrado.
  int encryptedBlockOffset(int index) {
    _checkIndex(index);
    return VaultHeader.length + index * (blockSize + blockOverhead);
  }

  /// Bloque que contiene el byte en claro [plainOffset].
  int blockIndexForOffset(int plainOffset) {
    if (plainOffset < 0 || plainOffset >= plaintextLength) {
      throw RangeError.range(plainOffset, 0, plaintextLength - 1, 'offset');
    }
    return plainOffset ~/ blockSize;
  }

  void _checkIndex(int index) {
    if (index < 0 || index >= blockCount) {
      throw RangeError.range(index, 0, blockCount - 1, 'index');
    }
  }
}

// -----------------------------------------------------------------------------
// Cifrado de un bloque
// -----------------------------------------------------------------------------

class VaultBlockCipher {
  /// [backend] fija la implementación AES-GCM (pruebas); por defecto se usa
  /// [AesGcmBackend.current] en cada operación (nativo con respaldo Dart en
  /// Android/iOS, D22). Todos los backends producen los mismos bytes.
  VaultBlockCipher({Random? random, AesGcmBackend? backend})
    : _random = random ?? Random.secure(),
      _backend = backend;

  final Random _random;
  final AesGcmBackend? _backend;

  AesGcmBackend get _aes => _backend ?? AesGcmBackend.current;

  /// AAD = encabezado ‖ índice (uint64 LE) ‖ isFinal (1 byte).
  static Uint8List aad(VaultHeader header, int index, bool isFinal) {
    final out = Uint8List(VaultHeader.length + 8 + 1);
    out.setRange(0, VaultHeader.length, header.bytes);
    ByteData.sublistView(
      out,
    ).setUint64(VaultHeader.length, index, Endian.little);
    out[VaultHeader.length + 8] = isFinal ? 1 : 0;
    return out;
  }

  /// Devuelve nonce ‖ ciphertext ‖ tag.
  Future<Uint8List> seal(
    VaultHeader header,
    int index,
    bool isFinal,
    List<int> plain,
    SecretKey key,
  ) async {
    final nonce = Uint8List(VaultLayout.nonceLength);
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = _random.nextInt(256);
    }
    final box = await _aes.encrypt(
      plain,
      secretKey: key,
      nonce: nonce,
      aad: aad(header, index, isFinal),
    );
    final out = Uint8List(plain.length + VaultLayout.blockOverhead);
    out.setRange(0, VaultLayout.nonceLength, nonce);
    out.setRange(
      VaultLayout.nonceLength,
      VaultLayout.nonceLength + plain.length,
      box.cipherText,
    );
    out.setRange(
      VaultLayout.nonceLength + plain.length,
      out.length,
      box.mac.bytes,
    );
    return out;
  }

  /// Verifica y descifra nonce ‖ ciphertext ‖ tag.
  Future<Uint8List> open(
    VaultHeader header,
    int index,
    bool isFinal,
    Uint8List block,
    SecretKey key,
  ) async {
    if (block.length < VaultLayout.blockOverhead) {
      throw VaultFormatException('Bloque $index truncado');
    }
    final tagStart = block.length - VaultLayout.tagLength;
    final box = SecretBox(
      Uint8List.sublistView(block, VaultLayout.nonceLength, tagStart),
      nonce: Uint8List.sublistView(block, 0, VaultLayout.nonceLength),
      mac: Mac(Uint8List.sublistView(block, tagStart)),
    );
    try {
      final plain = await _aes.decrypt(
        box,
        secretKey: key,
        aad: aad(header, index, isFinal),
      );
      return plain is Uint8List ? plain : Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw VaultAuthException(
        'Bloque $index no autentica: llave incorrecta o archivo alterado, '
        'reordenado, truncado o mezclado con otro archivo',
        blockIndex: index,
      );
    }
  }
}

// -----------------------------------------------------------------------------
// Operaciones completas
// -----------------------------------------------------------------------------

class VaultFileFormat {
  VaultFileFormat({Random? random, AesGcmBackend? backend})
    : _random = random ?? Random.secure(),
      _backend = backend,
      _cipher = VaultBlockCipher(random: random, backend: backend);

  final AesGcmBackend? _backend;

  final Random _random;
  final VaultBlockCipher _cipher;

  /// Cifra [source] hacia [dest] en streaming (≈ 2 bloques en RAM).
  ///
  /// El final se detecta leyendo por adelantado (no se confía en la longitud
  /// del origen), así un archivo de N·blockSize bytes termina en un bloque
  /// final completo. Si algo falla, [dest] se borra.
  Future<VaultHeader> encryptFile(
    File source,
    File dest,
    SecretKey key, {
    int blockSize = VaultHeader.defaultBlockSize,
  }) async {
    final header = VaultHeader.generate(blockSize: blockSize, random: _random);
    final input = await source.open(mode: FileMode.read);
    RandomAccessFile? output;
    var ok = false;
    try {
      output = await dest.open(mode: FileMode.write);
      await output.writeFrom(header.bytes);
      var current = await _readFully(input, blockSize);
      for (var index = 0; ; index++) {
        final next = current.length < blockSize
            ? Uint8List(0)
            : await _readFully(input, blockSize);
        final isFinal = next.isEmpty;
        await output.writeFrom(
          await _cipher.seal(header, index, isFinal, current, key),
        );
        if (isFinal) break;
        current = next;
      }
      await output.flush();
      ok = true;
      return header;
    } finally {
      await input.close();
      await output?.close();
      if (!ok) await _deleteQuietly(dest);
    }
  }

  /// Descifra [source] completo hacia [dest] en streaming. Si cualquier
  /// bloque falla, [dest] se borra y se relanza la excepción.
  Future<void> decryptFile(File source, File dest, SecretKey key) async {
    final reader = await VaultFileReader.open(
      source,
      key,
      verifyFinal: false,
      backend: _backend,
    );
    RandomAccessFile? output;
    var ok = false;
    try {
      output = await dest.open(mode: FileMode.write);
      for (var i = 0; i < reader.blockCount; i++) {
        await output.writeFrom(await reader.decryptBlock(i));
      }
      await output.flush();
      ok = true;
    } finally {
      await reader.close();
      await output?.close();
      if (!ok) await _deleteQuietly(dest);
    }
  }

  /// Descifra solo el bloque [index] (abre y cierra el archivo).
  Future<Uint8List> decryptBlock(File source, int index, SecretKey key) async {
    final reader = await VaultFileReader.open(
      source,
      key,
      verifyFinal: false,
      backend: _backend,
    );
    try {
      return await reader.decryptBlock(index);
    } finally {
      await reader.close();
    }
  }

  /// Cifra bytes en memoria con el mismo formato v2 (para miniaturas, con la
  /// subllave "thumbs").
  Future<Uint8List> encryptBytes(
    List<int> plain,
    SecretKey key, {
    int blockSize = VaultHeader.defaultBlockSize,
  }) async {
    final header = VaultHeader.generate(blockSize: blockSize, random: _random);
    final layout = VaultLayout.forPlaintext(plain.length, blockSize);
    final out = Uint8List(layout.encryptedLength);
    out.setRange(0, VaultHeader.length, header.bytes);
    for (var i = 0; i < layout.blockCount; i++) {
      final start = i * blockSize;
      final chunk = plain is Uint8List
          ? Uint8List.sublistView(
              plain,
              start,
              start + layout.plainBlockLength(i),
            )
          : plain.sublist(start, start + layout.plainBlockLength(i));
      final sealed = await _cipher.seal(
        header,
        i,
        layout.isFinal(i),
        chunk,
        key,
      );
      out.setAll(layout.encryptedBlockOffset(i), sealed);
    }
    return out;
  }

  /// Descifra bytes producidos por [encryptBytes] (o un `.vault` completo).
  Future<Uint8List> decryptBytes(
    List<int> encrypted,
    SecretKey key, {
    String? expectedFileId,
  }) async {
    final data = encrypted is Uint8List
        ? encrypted
        : Uint8List.fromList(encrypted);
    final header = VaultHeader.parse(data);
    if (expectedFileId != null && header.fileIdString != expectedFileId) {
      throw const VaultFileMismatchException();
    }
    final layout = VaultLayout.fromEncryptedLength(
      data.length,
      header.blockSize,
    );
    final out = Uint8List(layout.plaintextLength);
    for (var i = 0; i < layout.blockCount; i++) {
      final off = layout.encryptedBlockOffset(i);
      final plain = await _cipher.open(
        header,
        i,
        layout.isFinal(i),
        Uint8List.sublistView(data, off, off + layout.encryptedBlockLength(i)),
        key,
      );
      out.setAll(i * layout.blockSize, plain);
    }
    return out;
  }
}

// -----------------------------------------------------------------------------
// Lector con acceso aleatorio (base para streaming de video en F6)
// -----------------------------------------------------------------------------

/// Mantiene abierto un `.vault` y descifra bloques o rangos en claro.
/// Las operaciones se serializan internamente (RandomAccessFile no admite
/// operaciones concurrentes). Llamar a [close] al terminar.
class VaultFileReader {
  VaultFileReader._(
    this._raf,
    this.header,
    this.layout,
    this._key,
    AesGcmBackend? backend,
  ) : _cipher = VaultBlockCipher(backend: backend);

  final RandomAccessFile _raf;
  final VaultHeader header;
  final VaultLayout layout;
  final SecretKey _key;
  final VaultBlockCipher _cipher;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  int get blockCount => layout.blockCount;
  int get blockSize => layout.blockSize;

  /// Tamaño total en claro (autenticado si se abrió con verifyFinal=true).
  int get plaintextLength => layout.plaintextLength;

  /// Abre [file] y valida encabezado y longitud.
  ///
  /// Con [verifyFinal] (por defecto) descifra ya el bloque final, lo que
  /// autentica el encabezado, el número de bloques y [plaintextLength]
  /// (detecta truncado aunque luego solo se lean bloques intermedios).
  static Future<VaultFileReader> open(
    File file,
    SecretKey key, {
    bool verifyFinal = true,
    AesGcmBackend? backend,
    String? expectedFileId,
  }) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await raf.length();
      final header = VaultHeader.parse(
        await _readFully(raf, VaultHeader.length),
      );
      // S-09: comparar con el fileId registrado ANTES de descifrar nada. El
      // encabezado está en la AAD de cada bloque, así que no se puede
      // falsear sin romper la autenticación.
      if (expectedFileId != null && header.fileIdString != expectedFileId) {
        throw const VaultFileMismatchException();
      }
      final layout = VaultLayout.fromEncryptedLength(length, header.blockSize);
      final reader = VaultFileReader._(raf, header, layout, key, backend);
      if (verifyFinal) await reader.decryptBlock(layout.blockCount - 1);
      return reader;
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  /// Descifra y verifica el bloque [index] (isFinal según la longitud física).
  Future<Uint8List> decryptBlock(int index) => _synchronized(() async {
    _checkOpen();
    final len = layout.encryptedBlockLength(index); // valida el índice
    await _raf.setPosition(layout.encryptedBlockOffset(index));
    final block = await _readFully(_raf, len);
    if (block.length != len) {
      throw VaultFormatException('Bloque $index truncado (el archivo cambió)');
    }
    return _cipher.open(header, index, layout.isFinal(index), block, _key);
  });

  /// Devuelve hasta [length] bytes en claro desde [offset] (se recorta al
  /// final del archivo).
  Future<Uint8List> readRange(int offset, int length) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamRange(offset, offset + length)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Emite el texto plano del rango [start, end) bloque a bloque.
  /// [end] por defecto es el final; se recorta a [plaintextLength].
  Stream<Uint8List> streamRange([int start = 0, int? end]) async* {
    final total = layout.plaintextLength;
    final stop = min(end ?? total, total);
    if (start < 0 || start > total) {
      throw RangeError.range(start, 0, total, 'start');
    }
    if (stop < start) throw RangeError.range(stop, start, total, 'end');
    if (stop == start) return;
    final first = start ~/ blockSize;
    final last = (stop - 1) ~/ blockSize;
    for (var i = first; i <= last; i++) {
      final plain = await decryptBlock(i);
      final blockStart = i * blockSize;
      final from = max(start - blockStart, 0);
      final to = min(stop - blockStart, plain.length);
      yield Uint8List.sublistView(plain, from, to);
    }
  }

  Future<void> close() => _synchronized(() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  });

  void _checkOpen() {
    if (_closed) throw StateError('VaultFileReader cerrado');
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }
}

// -----------------------------------------------------------------------------
// Utilidades
// -----------------------------------------------------------------------------

/// Lee hasta [count] bytes; solo devuelve menos si llega al EOF.
Future<Uint8List> _readFully(RandomAccessFile raf, int count) async {
  final buffer = Uint8List(count);
  var filled = 0;
  while (filled < count) {
    final n = await raf.readInto(buffer, filled, count);
    if (n <= 0) break;
    filled += n;
  }
  return filled == count ? buffer : Uint8List.sublistView(buffer, 0, filled);
}

Future<void> _deleteQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } catch (_) {
    // Mejor esfuerzo: el error original es el relevante.
  }
}
