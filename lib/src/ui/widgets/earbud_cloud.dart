import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class EarbudCloud extends StatefulWidget {
  const EarbudCloud({super.key, required this.child});

  final Widget child;

  @override
  State<EarbudCloud> createState() => _EarbudCloudState();
}

class _EarbudCloudState extends State<EarbudCloud>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 42),
  );
  late final AppLifecycleListener _lifecycle;
  AppLifecycleState? _appState;
  bool _allowMotion = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _appState = WidgetsBinding.instance.lifecycleState;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _appState = state;
        _updateMotion();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowMotion =
        TickerMode.of(context) && !MediaQuery.disableAnimationsOf(context);
    _updateMotion();
  }

  void _updateMotion() {
    final isVisible =
        _appState == null ||
        _appState == AppLifecycleState.resumed ||
        _appState == AppLifecycleState.inactive;
    if (_allowMotion && isVisible) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final tint = theme.colorScheme.primary.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.39 : 0.27,
    );
    return SizedBox(
      width: 760,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: -34,
            right: -34,
            top: -64,
            bottom: -80,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _CloudPainter(tint, _motion)),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _CloudLobe {
  const _CloudLobe({
    required this.center,
    required this.radii,
    required this.drift,
    required this.tilt,
    required this.phase,
    required this.opacity,
  });

  final Offset center;
  final Offset radii;
  final Offset drift;
  final double tilt;
  final double phase;
  final double opacity;
}

class _CloudPainter extends CustomPainter {
  _CloudPainter(this.tint, this.motion) : super(repaint: motion);

  static const _lobes = [
    _CloudLobe(
      center: Offset(0.50, 0.53),
      radii: Offset(0.45, 0.39),
      drift: Offset(0.025, 0.025),
      tilt: 0.06,
      phase: 0,
      opacity: 0.88,
    ),
    _CloudLobe(
      center: Offset(0.27, 0.40),
      radii: Offset(0.25, 0.18),
      drift: Offset(0.052, 0.047),
      tilt: 0.38,
      phase: 0.8,
      opacity: 0.83,
    ),
    _CloudLobe(
      center: Offset(0.20, 0.59),
      radii: Offset(0.20, 0.15),
      drift: Offset(0.044, 0.051),
      tilt: -0.30,
      phase: 2.3,
      opacity: 0.71,
    ),
    _CloudLobe(
      center: Offset(0.73, 0.59),
      radii: Offset(0.25, 0.19),
      drift: Offset(0.057, 0.054),
      tilt: 0.34,
      phase: 3.8,
      opacity: 0.85,
    ),
    _CloudLobe(
      center: Offset(0.80, 0.39),
      radii: Offset(0.20, 0.14),
      drift: Offset(0.040, 0.047),
      tilt: -0.30,
      phase: 5.2,
      opacity: 0.74,
    ),
  ];

  final Color tint;
  final Animation<double> motion;
  late final _paints = [
    for (final lobe in _lobes)
      Paint()
        ..shader = RadialGradient(
          colors: [
            tint.withValues(alpha: tint.a * lobe.opacity),
            tint.withValues(alpha: tint.a * lobe.opacity * 0.70),
            tint.withValues(alpha: tint.a * lobe.opacity * 0.22),
            tint.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 0.75, 1],
        ).createShader(const Rect.fromLTWH(-1, -1, 2, 2)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cycle = motion.value * 2 * math.pi;
    canvas.save();
    canvas.scale(size.width, size.height);
    for (var i = 0; i < _lobes.length; i++) {
      final lobe = _lobes[i];
      final phase = cycle + lobe.phase;
      final sweep = math.sin(phase);
      final rise = math.cos(phase);

      canvas.save();
      canvas.translate(
        lobe.center.dx + lobe.drift.dx * sweep,
        lobe.center.dy + lobe.drift.dy * rise,
      );
      canvas.rotate(lobe.tilt + 0.25 * sweep);
      canvas.scale(
        lobe.radii.dx * (1 + 0.19 * rise),
        lobe.radii.dy * (1 - 0.13 * rise),
      );
      canvas.drawCircle(Offset.zero, 1, _paints[i]);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloudPainter oldDelegate) =>
      oldDelegate.tint != tint || oldDelegate.motion != motion;
}
