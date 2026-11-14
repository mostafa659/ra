import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Page background: a soft emerald gradient, a faint eight-pointed-star lattice (khatam) and a slowly drifting
/// golden glow. The lattice is painted once (never repaints); only the glow animates, inside its own
/// [RepaintBoundary]. With "remove animations" the glow stays still.
class IslamicPatternBackground extends StatefulWidget {
  const IslamicPatternBackground({super.key, required this.child, this.patternOpacity = 0.07});

  final Widget child;
  final double patternOpacity;

  @override
  State<IslamicPatternBackground> createState() => _IslamicPatternBackgroundState();
}

class _IslamicPatternBackgroundState extends State<IslamicPatternBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (!reduceMotion(context)) {
      _drift.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[scheme.surface, scheme.surfaceContainer],
            ),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _GlowPainter(_drift, scheme.secondary),
            size: Size.infinite,
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _LatticePainter(scheme.primary.withValues(alpha: widget.patternOpacity)),
            size: Size.infinite,
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// Eight-pointed star outline centred on ([cx], [cy]) with outer radius [r].
Path starPath(double cx, double cy, double r, {double inner = 0.62}) {
  final Path path = Path();
  for (int i = 0; i < 16; i++) {
    final double a = i * math.pi / 8 - math.pi / 2;
    final double rr = i.isEven ? r : r * inner;
    final double x = cx + rr * math.cos(a);
    final double y = cy + rr * math.sin(a);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

class _LatticePainter extends CustomPainter {
  const _LatticePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double cell = 84;
    final Paint line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Paint dot = Paint()..color = color;
    int row = 0;
    for (double y = 0; y < size.height + cell; y += cell * 0.5) {
      final double shift = row.isEven ? 0 : cell * 0.5;
      for (double x = -cell + shift; x < size.width + cell; x += cell) {
        canvas.drawPath(starPath(x, y, cell * 0.36), line);
        canvas.drawCircle(Offset(x, y), 1.6, dot);
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _LatticePainter oldDelegate) => oldDelegate.color != color;
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.animation, this.color) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = Curves.easeInOut.transform(animation.value);
    final Offset c = Offset(size.width * (0.25 + 0.5 * t), size.height * (0.12 + 0.06 * t));
    final double r = size.shortestSide * 0.9;
    final Paint p = Paint()
      ..shader = RadialGradient(
        colors: <Color>[color.withValues(alpha: 0.16), color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, p);
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) => oldDelegate.color != color;
}
