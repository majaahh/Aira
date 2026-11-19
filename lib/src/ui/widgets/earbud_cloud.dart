import 'dart:math' as math;
import 'dart:ui' as ui show Image, PictureRecorder;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';

class EarbudCloud extends StatefulWidget {
  const EarbudCloud({super.key, required this.child});

  final Widget child;

  @override
  State<EarbudCloud> createState() => _EarbudCloudState();
}

class _EarbudCloudState extends State<EarbudCloud>
    with
        TickerProviderStateMixin,
        AutomaticKeepAliveClientMixin,
        WidgetsBindingObserver {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 76),
  );
  late final _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1120),
    reverseDuration: const Duration(milliseconds: 950),
  );
  late final AppLifecycleListener _lifecycle;
  AppLifecycleState? _appState;
  int _seed = math.Random().nextInt(1 << 32);
  bool _allowMotion = false;
  bool _reduceMotion = false;
  bool _playReveal = true;
  bool _revealQueued = false;
  bool _keyboardVisible = false;
  ScrollPosition? _scrollPosition;
  bool get _isScrolling => _scrollPosition?.isScrollingNotifier.value == true;
  bool _inViewport = true;
  bool _viewportCheckQueued = false;
  _CloudPainter? _painter;
  bool _leavingActivity = false;
  final _android = defaultTargetPlatform == TargetPlatform.android;
  static const _activity = MethodChannel('io.majaahh.aira/activity');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appState = WidgetsBinding.instance.lifecycleState;
    if (_android) {
      _activity.setMethodCallHandler((call) async {
        if (call.method == 'userLeaveHint') {
          _leavingActivity = true;
          _updateMotion();
        }
      });
    }
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) _leavingActivity = false;
        if ((!_android || _leavingActivity) &&
            (state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused ||
                state == AppLifecycleState.detached)) {
          _playReveal = true;
          _reveal.value = 0;
        }
        _appState = state;
        _updateMotion();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != position) {
      _removeScrollListeners();
      _scrollPosition = position;
      position?.isScrollingNotifier.addListener(_onScrollActivity);
      position?.addListener(_onScrollOffsetChanged);
    }
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _allowMotion =
        Theme.of(context).brightness == Brightness.dark &&
        TickerMode.of(context) &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        !_reduceMotion;
    _keyboardVisible = View.of(context).viewInsets.bottom > 0;
    _onScrollActivity();
  }

  @override
  void didChangeMetrics() {
    _keyboardVisible = View.of(context).viewInsets.bottom > 0;
    _onScrollActivity();
  }

  void _onScrollOffsetChanged() {
    // jumpTo can change the offset without starting a scroll activity.
    if (!_isScrolling) _onScrollActivity();
  }

  void _removeScrollListeners() {
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrollActivity);
    _scrollPosition?.removeListener(_onScrollOffsetChanged);
  }

  void _onScrollActivity() {
    _updateMotion();
    if (_scrollPosition == null || _isScrolling || _viewportCheckQueued) return;
    _viewportCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportCheckQueued = false;
      if (!mounted || _isScrolling) return;
      final renderObject = context.findRenderObject();
      final viewport = RenderAbstractViewport.maybeOf(renderObject);
      if (renderObject == null || viewport == null || !renderObject.attached) {
        return;
      }
      // A kept-alive sliver child can still be attached after scrolling offscreen.
      final bounds = MatrixUtils.transformRect(
        renderObject.getTransformTo(viewport),
        renderObject.paintBounds,
      );
      _inViewport = bounds.isFinite && bounds.overlaps(viewport.paintBounds);
      _updateMotion();
    });
  }

  void _updateMotion() {
    if (_canAnimate) {
      if (!_motion.isAnimating) _motion.repeat();
      if (_playReveal && !_revealQueued) {
        _revealQueued = true;
        _reveal.value = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _revealQueued = false;
          if (!mounted || !_canAnimate) return;
          _playReveal = false;
          setState(() => _seed = math.Random().nextInt(1 << 32));
          _reveal.forward(from: 0);
        });
      } else if (!_playReveal &&
          !_reveal.isCompleted &&
          (!_reveal.isAnimating || _reveal.status == AnimationStatus.reverse)) {
        _reveal.forward();
      }
    } else {
      _motion.stop();
      if ((_android
              ? _leavingActivity
              : _appState == AppLifecycleState.inactive) &&
          _allowMotion &&
          !_keyboardVisible &&
          !_playReveal) {
        if (_reveal.status != AnimationStatus.reverse) _reveal.reverse();
      } else {
        _reveal.stop();
      }
      if (_reduceMotion &&
          (_appState == null || _appState == AppLifecycleState.resumed)) {
        _reveal.value = 1;
      }
    }
  }

  bool get _canAnimate =>
      _allowMotion &&
      _inViewport &&
      !_leavingActivity &&
      !_isScrolling &&
      !_keyboardVisible &&
      (_appState == null || _appState == AppLifecycleState.resumed);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_android) _activity.setMethodCallHandler(null);
    _lifecycle.dispose();
    _removeScrollListeners();
    _painter?.dispose();
    _motion.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    if (theme.brightness == Brightness.light) {
      _painter?.dispose();
      _painter = null;
      return SizedBox(width: 760, child: widget.child);
    }
    final tint = theme.colorScheme.primary.withValues(alpha: 0.48);
    if (_painter?.seed != _seed || _painter?.tint != tint) {
      _painter?.dispose();
      _painter = _CloudPainter(tint, _motion, _reveal, _seed);
    }
    return SizedBox(
      width: 760,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: -24,
            right: -24,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.transparent],
                    stops: [0, 0.77, 0.96],
                  ).createShader,
                  child: CustomPaint(painter: _painter),
                ),
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
  _CloudPainter(this.tint, this.motion, this.reveal, this.seed)
    : super(repaint: Listenable.merge([motion, reveal]));

  final Color tint;
  final Animation<double> motion;
  final Animation<double> reveal;
  final int seed;

  late final _lobes = _makeLobes();
  late final _grain = _makeGrain();

  List<_CloudLobe> _makeLobes() {
    final random = math.Random(seed);
    final lobes = <_CloudLobe>[];
    void addPuff(Offset center, double width, double height, double opacity) {
      lobes.add(
        _CloudLobe(
          center: center,
          radii: Offset(width, height),
          drift: const Offset(0.006, 0.004),
          tilt: (random.nextDouble() - 0.5) * 0.8,
          phase: random.nextDouble() * math.pi * 2,
          opacity: opacity,
        ),
      );
    }

    // Build the bright bank along a bent ridge behind the artwork. Its lower
    // shelf extends past the case, then thins as it curls up the right side.
    addPuff(const Offset(0.50, 0.47), 0.46, 0.30, 0.83);
    final ridge = Path()
      ..moveTo(0.16, 0.37)
      ..cubicTo(0.36, 0.25, 0.26, 0.60, 0.47, 0.64)
      ..cubicTo(0.66, 0.73, 0.84, 0.62, 0.81, 0.49)
      ..cubicTo(0.79, 0.39, 0.66, 0.39, 0.60, 0.33);
    final contour = ridge.computeMetrics().first;
    for (var i = 0; i < 25; i++) {
      final t = (i + random.nextDouble()) / 25;
      final point = contour.getTangentForOffset(t * contour.length)!;
      final normal = Offset(-point.vector.dy, point.vector.dx);
      final center =
          point.position + normal * ((random.nextDouble() - 0.5) * 0.07);
      final radius = 0.10 + 0.11 * math.sin(t * math.pi);
      addPuff(center, radius, radius * 0.77, 0.42 + random.nextDouble() * 0.22);
    }

    // Let a bank cross the physical top edge behind the system icons.
    final upperCenter = 0.22 + random.nextDouble() * 0.56;
    for (var i = 0; i < 5; i++) {
      addPuff(
        Offset(upperCenter + (i - 2) * 0.065, i * 0.014),
        0.12 + random.nextDouble() * 0.06,
        0.09,
        0.30,
      );
    }

    // Spread branching wisps through the entire hero. A different phase
    // and jitter on each launch keep the smaller banks unevenly spaced.
    final phase = random.nextDouble() * math.pi * 2;
    for (var i = 0; i < 32; i++) {
      final angle = phase + i * 2.39996 + random.nextDouble() * 0.36;
      final distance = math.sqrt((i + 1) / 32);
      var center = Offset(
        0.5 + 0.54 * distance * math.cos(angle),
        0.51 + 0.45 * distance * math.sin(angle),
      );
      var bearing = random.nextDouble() * math.pi * 2;
      final width = 0.09 + random.nextDouble() * 0.08;
      for (var branch = 0; branch < 3; branch++) {
        addPuff(
          center,
          width - branch * 0.016,
          width * (0.45 + random.nextDouble() * 0.34),
          0.20 + random.nextDouble() * 0.19,
        );
        bearing += random.nextDouble() - 0.5;
        center += Offset.fromDirection(bearing, 0.034);
      }
    }
    return lobes;
  }

  List<Float32List> _makeGrain() {
    final random = math.Random(seed);
    return List.generate(_lobes.length, (_) {
      final points = Float32List(80);
      for (var i = 0; i < points.length; i += 2) {
        final point = Offset.fromDirection(
          random.nextDouble() * 2 * math.pi,
          math.pow(random.nextDouble(), 0.7).toDouble() * 0.72,
        );
        points[i] = point.dx;
        points[i + 1] = point.dy;
      }
      return points;
    });
  }

  Size? _starSize;
  late List<Float32List> _starGroups;
  final _starPaint = Paint()..strokeCap = StrokeCap.round;

  void _paintStars(Canvas canvas, Size size) {
    if (_starSize?.width != size.width) {
      final random = math.Random(seed ^ 0x5a17);
      _starGroups = List.generate(8, (group) {
        final points = Float32List(96);
        for (var i = 0; i < points.length; i += 2) {
          points[i] = random.nextDouble() * size.width;
          points[i + 1] = random.nextDouble() * size.height;
        }
        return points;
      });
      _starSize = size;
    }
    canvas.save();
    canvas.scale(1, size.height / _starSize!.height);
    for (var i = 0; i < _starGroups.length; i++) {
      final progress = (reveal.value * 1.6 - i * 0.08).clamp(0.0, 1.0);
      _starPaint
        ..color = tint.withValues(alpha: progress * (0.13 + (i % 4) * 0.06))
        ..strokeWidth = 0.85 + (i % 3) * 0.55;
      canvas.drawRawPoints(PointMode.points, _starGroups[i], _starPaint);
    }
    canvas.restore();
  }

  // Bake the gradient and grain once per wisp. Only its transform and
  // reveal opacity change from frame to frame.
  static const _tile = 96;
  static const _columns = 12;
  ui.Image? _atlas;
  late final _sources = Float32List(_lobes.length * 4);
  late final _transforms = Float32List(_lobes.length * 4);
  late final _colors = Int32List(_lobes.length);
  final _atlasPaint = Paint()..filterQuality = FilterQuality.low;

  ui.Image _makeAtlas() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final grainPaint = Paint()
      ..color = tint.withValues(alpha: tint.a * 0.35)
      ..strokeWidth = 0.010
      ..strokeCap = StrokeCap.round;
    const bounds = Rect.fromLTWH(-1, -1, 2, 2);
    for (var i = 0; i < _lobes.length; i++) {
      final lobe = _lobes[i];
      final left = (i % _columns) * _tile.toDouble();
      final top = (i ~/ _columns) * _tile.toDouble();
      _sources.setAll(i * 4, [left, top, left + _tile, top + _tile]);
      final radius = math.max(lobe.radii.dx, lobe.radii.dy);
      final alpha = tint.a * lobe.opacity;
      final glow = Paint()
        ..shader = RadialGradient(
          colors: [
            tint.withValues(alpha: alpha),
            tint.withValues(alpha: alpha * 0.45),
            tint.withValues(alpha: alpha * 0.10),
            tint.withValues(alpha: 0),
          ],
          stops: const [0, 0.38, 0.72, 1],
        ).createShader(bounds);
      canvas.save();
      canvas.translate(left + _tile / 2, top + _tile / 2);
      canvas.scale(
        (_tile / 2 - 1) * lobe.radii.dx / radius,
        (_tile / 2 - 1) * lobe.radii.dy / radius,
      );
      canvas.drawCircle(Offset.zero, 1, glow);
      canvas.drawRawPoints(PointMode.points, _grain[i], grainPaint);
      canvas.restore();
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      _columns * _tile,
      (_lobes.length / _columns).ceil() * _tile,
    );
    picture.dispose();
    return image;
  }

  void dispose() => _atlas?.dispose();

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal.value == 0 || size.isEmpty) return;
    final atlas = _atlas ??= _makeAtlas();
    final cycle = motion.value * 2 * math.pi;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width, size.height);
    for (var i = 0; i < _lobes.length; i++) {
      final delay = i == 0 ? 0.0 : 0.08 + i / (_lobes.length - 1) * 0.52;
      final progress = ((reveal.value - delay) / (i == 0 ? 0.58 : 0.40)).clamp(
        0.0,
        1.0,
      );
      if (progress == 0) {
        _colors[i] = 0;
        continue;
      }
      final growth = Curves.easeOutCubic.transform(progress);
      final opacity = Curves.easeInOutCubic.transform(progress);
      final settling = 1 - growth;
      final scale = 0.46 + growth * 0.54;
      final lobe = _lobes[i];
      final phase = cycle * (i.isEven ? 1 : 2) + lobe.phase;
      final sweep = math.sin(phase);
      final rise = math.cos(phase);

      final x =
          lobe.center.dx +
          lobe.drift.dx * sweep +
          settling * 0.09 * math.cos(lobe.phase);
      final y = lobe.center.dy + lobe.drift.dy * rise + settling * 0.05 * rise;
      final rotation = lobe.tilt + 0.07 * sweep;
      final radius = math.max(lobe.radii.dx, lobe.radii.dy);
      final zoom = radius * scale * (1 + 0.04 * rise) / (_tile / 2 - 1);
      final scos = zoom * math.cos(rotation);
      final ssin = zoom * math.sin(rotation);
      final j = i * 4;
      _transforms[j] = scos;
      _transforms[j + 1] = ssin;
      _transforms[j + 2] = x - _tile / 2 * (scos - ssin);
      _transforms[j + 3] = y - _tile / 2 * (scos + ssin);
      _colors[i] = ((opacity * 255).round() << 24) | 0x00ffffff;
    }
    canvas.drawRawAtlas(
      atlas,
      _transforms,
      _sources,
      reveal.isCompleted ? null : _colors,
      BlendMode.modulate,
      null,
      _atlasPaint,
    );
    canvas.restore();
    _paintStars(canvas, size);
  }

  @override
  bool shouldRepaint(_CloudPainter oldDelegate) =>
      oldDelegate.tint != tint ||
      oldDelegate.motion != motion ||
      oldDelegate.reveal != reveal ||
      oldDelegate.seed != seed;
}
