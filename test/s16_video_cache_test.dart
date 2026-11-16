// S-16: la caché de compresión de video (en claro) se barre al arrancar, y
// ese barrido es best-effort: ningún error (ni `kotlin.Unit`) impide el arranque.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/gallery/video_compressor.dart';

class _FakeCleanupCompressor implements VideoCompressor {
  _FakeCleanupCompressor(this.error);

  /// Lo que lanza `cleanup()`; null = éxito.
  final Object? error;
  int cleanups = 0;

  @override
  Future<CompressedVideo?> compress(
    File source,
    VideoQualityOption quality, {
    void Function(double progress)? onProgress,
  }) async => null;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> cleanup() async {
    cleanups++;
    if (error != null) throw error!;
  }
}

void main() {
  test('S-16 el barrido de arranque llama a cleanup una vez', () async {
    final c = _FakeCleanupCompressor(null);
    await sweepVideoCompressorCacheAtStartup(c);
    expect(c.cleanups, 1);
  });

  test('S-16 un error nativo no impide el arranque', () async {
    final c = _FakeCleanupCompressor(StateError('fallo nativo'));
    await expectLater(sweepVideoCompressorCacheAtStartup(c), completes);
    expect(c.cleanups, 1);
  });

  test('S-16 un lanzamiento de kotlin.Unit (no Exception) se ignora', () async {
    final c = _FakeCleanupCompressor('kotlin.Unit');
    await expectLater(sweepVideoCompressorCacheAtStartup(c), completes);
    expect(c.cleanups, 1);
  });
}
