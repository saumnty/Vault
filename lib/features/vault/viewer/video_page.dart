import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/models/vault_item_model.dart';
import '../vault_services.dart';
import 'media_opener.dart';
import 'photo_page.dart';
import 'video_gestures.dart';
import 'viewer_dismiss.dart';

/// "1:05" / "1:02:03".
String formatDuration(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

enum _VideoState { idle, opening, ready, error }

/// Página de video.
///
/// No abre nada hasta que el usuario toca "Reproducir": así deslizar por la
/// carpeta no dispara descargas/descifrados de videos grandes. Al salir de la
/// página (o cerrar el visor) se libera el origen: cierra el servidor local
/// de streaming (F6b) o borra el temporal (respaldo completo-primero).
/// Al pasar la app a segundo plano también se libera (se recuerda la
/// posición y se reanuda desde ahí al volver a tocar Reproducir): así no
/// queda un servidor escuchando con la app oculta.
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.item,
    required this.opener,
    required this.heroTag,
    required this.chromeVisible,
    required this.onTap,
    this.thumbnailLoader,
    this.onFullscreenChanged,
    this.onZoomChanged,
  });

  final VaultItemModel item;
  final MediaOpener opener;
  final String heroTag;
  final bool chromeVisible;
  final VoidCallback onTap;
  final ThumbnailLoader? thumbnailLoader;

  /// Pantalla completa del reproductor (el visor oculta su barra).
  final ValueChanged<bool>? onFullscreenChanged;

  /// El video está ampliado (>1x): el visor no pagina ni cierra deslizando.
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> with WidgetsBindingObserver {
  _VideoState _state = _VideoState.idle;
  VideoSource? _source;
  VideoPlayerController? _controller;
  MediaProgress? _progress;
  MediaOpenError? _error;
  ImageProvider? _thumb;
  bool _fullscreen = false;
  bool _disposed = false;

  /// Posición a la que volver tras liberar por segundo plano.
  Duration? _resumeAt;

  /// Medición de arranque (solo logs de depuración/perfil).
  Stopwatch? _startWatch;
  bool _firstFrameLogged = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadThumb());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onValue);
    final source = _source;
    _source = null;
    if (source != null) unawaited(source.release());
    if (_fullscreen) unawaited(_applyFullscreen(false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(_suspend());
    }
  }

  /// Segundo plano: libera el origen (servidor/temporal) y vuelve a "idle"
  /// recordando la posición.
  Future<void> _suspend() async {
    final source = _source;
    if (source == null) return;
    final c = _controller;
    if (c != null && c.value.isInitialized) _resumeAt = c.value.position;
    c?.removeListener(_onValue);
    _source = null;
    _controller = null;
    if (_fullscreen) {
      _fullscreen = false;
      unawaited(_applyFullscreen(false));
      widget.onFullscreenChanged?.call(false);
    }
    if (!_disposed && mounted) setState(() => _state = _VideoState.idle);
    await source.release();
  }

  /// Errores del reproductor DURANTE la reproducción (p. ej. el servidor
  /// cortó la respuesta porque un bloque no autenticó).
  void _onValue() {
    final c = _controller;
    if (c == null || _disposed || !mounted) return;
    final v = c.value;
    if (!_firstFrameLogged &&
        v.isPlaying &&
        v.position > Duration.zero &&
        !kReleaseMode) {
      _firstFrameLogged = true;
      debugPrint(
        '[vault-video] primer avance de posición a los '
        '${_startWatch?.elapsedMilliseconds} ms del toque',
      );
    }
    if (!v.hasError || _state != _VideoState.ready) return;
    final source = _source;
    final cause = source?.playbackFailure ?? const VideoPlaybackException();
    c.removeListener(_onValue);
    _source = null;
    _controller = null;
    setState(() {
      _error = describeMediaError(cause);
      _state = _VideoState.error;
    });
    if (source != null) unawaited(source.release());
  }

  Future<void> _loadThumb() async {
    final loader = widget.thumbnailLoader;
    if (loader == null || widget.item.thumbPath == null) return;
    try {
      final t = await loader(widget.item);
      if (!_disposed && mounted) setState(() => _thumb = t);
    } on Object {
      // sin miniatura
    }
  }

  Future<void> _start() async {
    final old = _source;
    _source = null;
    _controller?.removeListener(_onValue);
    if (old != null) await old.release();
    _startWatch = Stopwatch()..start();
    _firstFrameLogged = false;
    final source = widget.opener.videoSource(widget.item);
    _source = source;
    setState(() {
      _state = _VideoState.opening;
      _progress = null;
      _error = null;
    });
    try {
      final controller = await source.open(
        onProgress: (p) {
          if (!_disposed && mounted && identical(_source, source)) {
            setState(() => _progress = p);
          }
        },
      );
      if (_disposed || !mounted || !identical(_source, source)) {
        await source.release();
        return;
      }
      _controller = controller;
      controller.addListener(_onValue);
      if (!kReleaseMode) {
        debugPrint(
          '[vault-video] inicializado a los '
          '${_startWatch?.elapsedMilliseconds} ms del toque '
          '(${source.runtimeType})',
        );
      }
      setState(() => _state = _VideoState.ready);
      final resume = _resumeAt;
      _resumeAt = null;
      if (resume != null && resume > Duration.zero) {
        await controller.seekTo(resume);
      }
      await controller.play();
    } on Object catch (e) {
      await source.release();
      if (_disposed || !mounted || !identical(_source, source)) return;
      _source = null;
      setState(() {
        _controller = null;
        _error = describeMediaError(e);
        _state = _VideoState.error;
      });
    }
  }

  Future<void> _applyFullscreen(bool value) async {
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    unawaited(_applyFullscreen(_fullscreen));
    widget.onFullscreenChanged?.call(_fullscreen);
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: widget.heroTag,
      child: Material(
        type: MaterialType.transparency,
        child: switch (_state) {
          _VideoState.idle => _idle(),
          _VideoState.opening => _opening(),
          _VideoState.ready => _player(),
          _VideoState.error => _errorView(),
        },
      ),
    );
  }

  Widget _backdrop() => Stack(
    fit: StackFit.expand,
    children: [
      if (_thumb != null)
        Image(image: _thumb!, fit: BoxFit.contain, excludeFromSemantics: true),
    ],
  );

  Widget _idle() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: widget.onTap,
    child: Stack(
      fit: StackFit.expand,
      children: [
        _backdrop(),
        Center(
          child: Semantics(
            button: true,
            label: 'Reproducir video ${widget.item.name}',
            excludeSemantics: true,
            onTap: _start,
            child: GestureDetector(
              key: const ValueKey('video-play'),
              onTap: _start,
              child: Container(
                width: AppSizes.playButton,
                height: AppSizes.playButton,
                decoration: const BoxDecoration(
                  color: AppColors.scrim,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: AppSizes.iconHero,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _opening() => Stack(
    fit: StackFit.expand,
    children: [
      _backdrop(),
      Center(
        key: const ValueKey('video-opening'),
        child: ViewerProgress(
          progress: _progress,
          idleLabel: 'Preparando video…',
        ),
      ),
    ],
  );

  Widget _errorView() {
    final e = _error!;
    return ViewerMessage(
      key: const ValueKey('video-error'),
      icon: e.canRetry ? Icons.cloud_off_outlined : Icons.error_outline_rounded,
      title: 'No se pudo reproducir',
      message: e.message,
      actionLabel: e.canRetry ? 'Reintentar' : null,
      onAction: e.canRetry ? _start : null,
    );
  }

  Widget _player() {
    final c = _controller!;
    return Stack(
      fit: StackFit.expand,
      children: [
        VideoGestureLayer(
          controller: c,
          onTap: widget.onTap,
          child: ZoomableVideo(
            onZoomChanged: (z) => widget.onZoomChanged?.call(z),
            child: Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio == 0
                    ? 16 / 9
                    : c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: AnimatedOpacity(
              duration: AppMotion.fast,
              opacity: widget.chromeVisible ? 1 : 0,
              child: IgnorePointer(
                ignoring: !widget.chromeVisible,
                // Sobre los controles el arrastre vertical no cierra.
                child: ViewerDismissBlocker(
                  child: VideoControls(
                    controller: c,
                    fullscreen: _fullscreen,
                    onToggleFullscreen: _toggleFullscreen,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Controles propios: reproducir/pausar, barra de búsqueda, tiempo y pantalla
/// completa. Todo con tokens y áreas táctiles >= 44.
class VideoControls extends StatefulWidget {
  const VideoControls({
    super.key,
    required this.controller,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final VideoPlayerController controller;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, v, _) {
        final totalMs = v.duration.inMilliseconds.toDouble();
        final posMs = (_dragMs ?? v.position.inMilliseconds.toDouble()).clamp(
          0.0,
          totalMs <= 0 ? 1.0 : totalMs,
        );
        final ended = totalMs > 0 && v.position >= v.duration && !v.isPlaying;
        return Padding(
          padding: AppSpacing.page,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: AppColors.scrim,
              borderRadius: AppRadii.lgAll,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              // Altura acotada: el Slider ocupa todo el alto disponible.
              child: SizedBox(
                height: AppSizes.toolbar,
                child: Row(
                  children: [
                    _ControlButton(
                      icon: v.isPlaying
                          ? Icons.pause_rounded
                          : (ended
                                ? Icons.replay_rounded
                                : Icons.play_arrow_rounded),
                      label: v.isPlaying
                          ? 'Pausar'
                          : (ended ? 'Reproducir de nuevo' : 'Reproducir'),
                      onPressed: () async {
                        if (v.isPlaying) {
                          await c.pause();
                        } else {
                          if (ended) await c.seekTo(Duration.zero);
                          await c.play();
                        }
                      },
                    ),
                    Text(
                      formatDuration(Duration(milliseconds: posMs.round())),
                      style: AppTypography.caption,
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: AppSizes.progressBarHeight,
                          activeTrackColor: AppColors.accentLight,
                          inactiveTrackColor: AppColors.overlayLight,
                          thumbColor: AppColors.accentLight,
                          overlayColor: AppColors.glow,
                        ),
                        child: Semantics(
                          label: 'Posición del video',
                          value:
                              '${formatDuration(Duration(milliseconds: posMs.round()))} '
                              'de ${formatDuration(v.duration)}',
                          child: Slider(
                            key: const ValueKey('video-seek'),
                            min: 0,
                            max: totalMs <= 0 ? 1 : totalMs,
                            value: posMs,
                            onChanged: totalMs <= 0
                                ? null
                                : (x) => setState(() => _dragMs = x),
                            onChangeEnd: (x) async {
                              setState(() => _dragMs = null);
                              await c.seekTo(Duration(milliseconds: x.round()));
                            },
                          ),
                        ),
                      ),
                    ),
                    Text(
                      formatDuration(v.duration),
                      style: AppTypography.caption,
                    ),
                    _ControlButton(
                      icon: widget.fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      label: widget.fullscreen
                          ? 'Salir de pantalla completa'
                          : 'Pantalla completa',
                      onPressed: widget.onToggleFullscreen,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: AppColors.textPrimary),
      tooltip: label,
      onPressed: onPressed,
      constraints: const BoxConstraints(
        minWidth: AppSizes.minTouch,
        minHeight: AppSizes.minTouch,
      ),
    );
  }
}
