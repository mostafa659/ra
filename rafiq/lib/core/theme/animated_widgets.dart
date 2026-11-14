import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'app_theme.dart';

/// Rounded progress bar whose fill animates smoothly to every new [value] (0..1).
class AnimatedProgressBar extends StatelessWidget {
  const AnimatedProgressBar({super.key, required this.value, this.height = 8, this.color});

  final double value;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = color ?? scheme.secondary;
    final double target = value.clamp(0.0, 1.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: scheme.onSurface.withValues(alpha: 0.12),
        alignment: AlignmentDirectional.centerStart,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: target),
          duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 800),
          curve: AppMotion.enter,
          builder: (BuildContext context, double v, Widget? child) {
            return FractionallySizedBox(widthFactor: v, child: child);
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height),
              gradient: LinearGradient(colors: <Color>[fill.withValues(alpha: 0.75), fill]),
            ),
            child: SizedBox(height: height),
          ),
        ),
      ),
    );
  }
}

/// Gently "breathing" glow and scale around [child] (logo, hero element).
class BreathingGlow extends StatefulWidget {
  const BreathingGlow({super.key, required this.child, required this.color, this.radius = 28});

  final Widget child;
  final Color color;
  final double radius;

  @override
  State<BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<BreathingGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
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
      _controller.repeat(reverse: true);
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
        final double t = Curves.easeInOut.transform(_controller.value);
        return Transform.scale(
          scale: 1.0 + 0.03 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.18 + 0.22 * t),
                  blurRadius: 24 + 22 * t,
                  spreadRadius: 1 + 5 * t,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// Round microphone button. While [listening] expanding gold rings pulse around it and the icon morphs
/// between mic and stop. [enabled] false greys it out (e.g. while the engine is busy).
class MicPulseButton extends StatefulWidget {
  const MicPulseButton({
    super.key,
    required this.listening,
    required this.enabled,
    required this.onPressed,
    required this.tooltip,
    this.size = 64,
  });

  final bool listening;
  final bool enabled;
  final VoidCallback onPressed;
  final String tooltip;
  final double size;

  @override
  State<MicPulseButton> createState() => _MicPulseButtonState();
}

class _MicPulseButtonState extends State<MicPulseButton> with SingleTickerProviderStateMixin {
  late final AnimationController _rings = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(MicPulseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool animate = widget.listening && !reduceMotion(context);
    if (animate && !_rings.isAnimating) {
      _rings.repeat();
    } else if (!animate && _rings.isAnimating) {
      _rings.stop();
      _rings.value = 0;
    }
  }

  @override
  void dispose() {
    _rings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double s = widget.size;
    final Color base = widget.listening ? AppColors.error : scheme.secondary;
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox(
        width: s * 1.6,
        height: s * 1.6,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            if (widget.listening)
              RepaintBoundary(
                child: CustomPaint(
                  size: Size.square(s * 1.6),
                  painter: _RingsPainter(_rings, base, s / 2),
                ),
              ),
            AnimatedContainer(
              duration: AppMotion.medium,
              curve: AppMotion.enter,
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.enabled
                      ? <Color>[Color.lerp(base, Colors.white, 0.25)!, base]
                      : <Color>[scheme.outlineVariant, scheme.outlineVariant],
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: base.withValues(alpha: widget.enabled ? 0.45 : 0),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.enabled ? widget.onPressed : null,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: AppMotion.fast,
                      transitionBuilder: (Widget child, Animation<double> a) => ScaleTransition(
                        scale: a,
                        child: RotationTransition(turns: Tween<double>(begin: 0.85, end: 1).animate(a), child: child),
                      ),
                      child: Icon(
                        widget.listening ? Icons.stop_rounded : Icons.mic_rounded,
                        key: ValueKey<bool>(widget.listening),
                        size: s * 0.46,
                        color: scheme.onSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.animation, this.color, this.baseRadius) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double baseRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double reach = size.shortestSide / 2 - baseRadius;
    for (int k = 0; k < 3; k++) {
      final double t = (animation.value + k / 3) % 1.0;
      final double r = baseRadius + reach * t;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = color.withValues(alpha: 0.32 * (1 - t))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * math.max(0.3, 1 - t),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingsPainter oldDelegate) => oldDelegate.color != color;
}
