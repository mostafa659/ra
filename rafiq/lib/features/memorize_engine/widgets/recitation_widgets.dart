import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/tajweed/arabic_text.dart';
import '../recitation_session_controller.dart';

/// Shakes its child whenever [shakeToken] changes.
class ShakeWidget extends StatefulWidget {
  const ShakeWidget({super.key, required this.shakeToken, required this.child});

  final int shakeToken;
  final Widget child;

  @override
  State<ShakeWidget> createState() => _ShakeWidgetState();
}

class _ShakeWidgetState extends State<ShakeWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  @override
  void didUpdateWidget(ShakeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shakeToken != widget.shakeToken) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double t = _controller.value;
        final double dx = math.sin(t * math.pi * 8) * 10 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

/// One word of the ayah. Plain text on a calm page: the status is the color of the word (and an
/// underline for anything that is not right, so it never relies on color alone); only the word being
/// read has a soft background. No boxes or borders.
class WordChip extends StatelessWidget {
  const WordChip({
    super.key,
    required this.text,
    required this.status,
    required this.isCurrent,
    required this.hidden,
    required this.showFirstLetter,
    required this.shakeToken,
    this.onTap,
  });

  /// Opens the explanation of what is wrong; null for words that have nothing to explain.
  final VoidCallback? onTap;
  final String text;
  final WordStatus status;
  final bool isCurrent;
  final bool hidden;
  final bool showFirstLetter;
  final int shakeToken;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    Color color = scheme.onSurface;
    Color background = Colors.transparent;
    TextDecoration decoration = TextDecoration.none;
    switch (status) {
      case WordStatus.correct:
        color = AppColors.correct;
        break;
      case WordStatus.warning:
      case WordStatus.uncertain:
        color = AppColors.warning;
        decoration = TextDecoration.underline;
        break;
      case WordStatus.incorrect:
        color = AppColors.error;
        decoration = TextDecoration.underline;
        background = Color.alphaBlend(AppColors.error.withAlpha(28), Colors.transparent);
        break;
      case WordStatus.pending:
        if (isCurrent) {
          background = Color.alphaBlend(scheme.primary.withAlpha(34), Colors.transparent);
        }
        break;
    }

    String display = text;
    if (hidden) {
      display = showFirstLetter ? '${firstLetterWithMarks(text)} …' : maskWord(text);
      if (status == WordStatus.pending) {
        color = scheme.onSurfaceVariant;
      }
    }

    final bool pop = status != WordStatus.pending;
    return ShakeWidget(
      shakeToken: shakeToken,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: TweenAnimationBuilder<double>(
          // A new key restarts the tween: the word "pops" once each time its verdict changes.
          key: ValueKey<WordStatus>(status),
          tween: Tween<double>(begin: pop && !reduceMotion(context) ? 0.9 : 1.0, end: 1.0),
          duration: const Duration(milliseconds: 420),
          curve: AppMotion.emphasized,
          builder: (BuildContext context, double scale, Widget? child) {
            return Transform.scale(scale: scale, child: child);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: AppMotion.enter,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              curve: AppMotion.enter,
              style: TextStyle(
                fontFamily: 'AmiriQuran',
                fontSize: hidden ? 26 : 30,
                height: 1.8,
                color: color,
                decoration: decoration,
                decorationColor: color,
                decorationThickness: 1.5,
              ),
              child: Text(display),
            ),
          ),
        ),
      ),
    );
  }
}

/// Live bar waveform driven by the microphone RMS level.
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({super.key, required this.levels, required this.color});

  final List<double> levels;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(levels: levels, color: color),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({required this.levels, required this.color});

  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    final int n = levels.length;
    if (n == 0) {
      return;
    }
    final double gap = size.width / n;
    final double mid = size.height / 2;
    for (int i = 0; i < n; i++) {
      final double h = math.max(3.0, levels[i] * size.height).toDouble();
      final double x = gap * i + gap / 2;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}
