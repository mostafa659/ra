import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'islamic_pattern.dart';

/// Ayah / surah number inside a gold eight-pointed star.
class StarBadge extends StatelessWidget {
  const StarBadge({super.key, required this.label, this.size = 46});

  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _StarBadgePainter(fill: scheme.secondary, ring: scheme.onSecondary.withValues(alpha: 0.55)),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: size * 0.36,
              fontWeight: FontWeight.w800,
              color: scheme.onSecondary,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

class _StarBadgePainter extends CustomPainter {
  const _StarBadgePainter({required this.fill, required this.ring});

  final Color fill;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    canvas.drawPath(
      starPath(c.dx, c.dy, r, inner: 0.78),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[AppColors.goldBright, fill],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c,
      r * 0.66,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
  }

  @override
  bool shouldRepaint(covariant _StarBadgePainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.ring != ring;
}

/// Thin gold line with a small star in the middle; separates sections without drawing a box.
class GoldDivider extends StatelessWidget {
  const GoldDivider({super.key, this.width = 180});

  final double width;

  @override
  Widget build(BuildContext context) {
    final Color gold = Theme.of(context).colorScheme.secondary;
    final Widget line = Expanded(
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: <Color>[gold.withValues(alpha: 0), gold.withValues(alpha: 0.7)]),
        ),
      ),
    );
    return SizedBox(
      width: width,
      child: Row(
        children: <Widget>[
          line,
          const SizedBox(width: 8),
          SizedBox(
            width: 14,
            height: 14,
            child: CustomPaint(painter: _MiniStarPainter(gold)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Transform.flip(
              flipX: true,
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient:
                      LinearGradient(colors: <Color>[gold.withValues(alpha: 0), gold.withValues(alpha: 0.7)]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStarPainter extends CustomPainter {
  const _MiniStarPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(starPath(size.width / 2, size.height / 2, size.width / 2), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MiniStarPainter oldDelegate) => oldDelegate.color != color;
}
