// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Plataforma de video falsa: `initialize` termina al instante y no reproduce
/// nada. Permite probar el reproductor sin ExoPlayer/AVPlayer.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  final List<String> calls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _position = {};
  int _next = 1;
  Duration duration = const Duration(seconds: 25);

  /// Rutas de archivo con las que se creó un reproductor.
  final List<String> openedUris = [];

  @override
  Future<void> init() async => calls.add('init');

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    openedUris.add(options.dataSource.uri ?? '');
    final c = StreamController<VideoEvent>();
    _events[id] = c;
    _position[id] = Duration.zero;
    scheduleMicrotask(
      () => c.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: duration,
          size: const Size(1920, 1080),
        ),
      ),
    );
    return id;
  }

  @override
  Future<int?> create(DataSource dataSource) async => createWithOptions(
    VideoCreationOptions(
      dataSource: dataSource,
      viewType: VideoViewType.textureView,
    ),
  );

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async => calls.add('play');
  @override
  Future<void> pause(int playerId) async => calls.add('pause');
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek');
    _position[playerId] = position;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async =>
      _position[playerId] ?? Duration.zero;
  @override
  Widget buildView(int playerId) => const SizedBox.expand();
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}
