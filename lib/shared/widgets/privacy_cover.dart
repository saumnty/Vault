import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';

/// Segunda capa multiplataforma de privacidad: mientras la app no está
/// activa (`inactive`, `hidden` o `paused`) tapa todo con una pantalla sólida
/// con el candado, para que la vista previa del selector de apps no muestre
/// contenido. La primera capa es nativa (FLAG_SECURE en Android, cobertura en
/// `SceneDelegate` en iOS).
class PrivacyCover extends StatefulWidget {
  const PrivacyCover({super.key, required this.child, this.state});

  final Widget child;

  /// Solo pruebas: fuerza el estado en vez de observar el ciclo de vida.
  final AppLifecycleState? state;

  @override
  State<PrivacyCover> createState() => _PrivacyCoverState();
}

class _PrivacyCoverState extends State<PrivacyCover>
    with WidgetsBindingObserver {
  AppLifecycleState? _state = WidgetsBinding.instance.lifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _state = state);
  }

  /// `null` (aún sin estado) cuenta como activa.
  static bool _covers(AppLifecycleState? s) =>
      s == AppLifecycleState.inactive ||
      s == AppLifecycleState.hidden ||
      s == AppLifecycleState.paused;

  @override
  Widget build(BuildContext context) {
    final covered = _covers(widget.state ?? _state);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (covered)
          const Positioned.fill(
            key: ValueKey('privacy-cover'),
            child: ColoredBox(
              color: AppColors.background,
              child: Center(
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.lock_rounded,
                    size: AppSizes.iconXl,
                    color: AppColors.accentLight,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
