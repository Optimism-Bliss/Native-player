import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../util/format.dart';

/// Seek bar in the style of Fladder's VideoProgressBar: thick rounded track,
/// buffered range, gap around a pill-shaped thumb that grows on hover/drag and
/// a time bubble while hovering or dragging.
class PlayerProgressBar extends StatefulWidget {
  const PlayerProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.buffering,
    required this.onSeek,
    this.onInteraction,
  });

  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool buffering;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onInteraction;

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar> {
  double? _hoverFraction;
  double? _dragFraction;

  double _fraction(Duration d) {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (d.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _at(double fraction) => Duration(milliseconds: (widget.duration.inMilliseconds * fraction).round());

  double _toFraction(double dx, double width) => width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final seekable = widget.duration > Duration.zero;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final active = _dragFraction != null || _hoverFraction != null;
        final shown = _dragFraction ?? _fraction(widget.position);
        final bubbleFraction = _dragFraction ?? _hoverFraction;
        return MouseRegion(
          cursor: seekable ? SystemMouseCursors.click : MouseCursor.defer,
          onHover: seekable ? (e) => setState(() => _hoverFraction = _toFraction(e.localPosition.dx, width)) : null,
          onExit: (_) => setState(() => _hoverFraction = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: seekable
                ? (d) {
                    widget.onInteraction?.call();
                    setState(() => _dragFraction = _toFraction(d.localPosition.dx, width));
                  }
                : null,
            onHorizontalDragUpdate: seekable
                ? (d) {
                    widget.onInteraction?.call();
                    setState(() => _dragFraction = _toFraction(d.localPosition.dx, width));
                  }
                : null,
            onHorizontalDragEnd: seekable
                ? (_) {
                    final f = _dragFraction;
                    setState(() => _dragFraction = null);
                    if (f != null) widget.onSeek(_at(f));
                  }
                : null,
            onTapUp: seekable
                ? (d) {
                    widget.onInteraction?.call();
                    widget.onSeek(_at(_toFraction(d.localPosition.dx, width)));
                  }
                : null,
            child: SizedBox(
              height: 28,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: active ? 1 : 0),
                      duration: const Duration(milliseconds: 125),
                      builder: (context, grow, _) => CustomPaint(
                        painter: _TrackPainter(
                          position: shown,
                          buffer: _fraction(widget.buffer),
                          hover: _hoverFraction,
                          grow: grow,
                          active: scheme.primary,
                          bufferColor: scheme.primary.withValues(alpha: 0.45),
                          inactive: scheme.onSurface.withValues(alpha: 0.22),
                          thumb: Color.lerp(scheme.primary, scheme.onSurface, grow)!,
                        ),
                      ),
                    ),
                  ),
                  if (widget.buffering)
                    Positioned.fill(
                      child: Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(100),
                          child: const LinearProgressIndicator(minHeight: 6, backgroundColor: Colors.transparent),
                        ),
                      ),
                    ),
                  if (bubbleFraction != null && seekable)
                    Positioned(
                      left: (bubbleFraction * width - 36).clamp(0.0, math.max(0.0, width - 72)),
                      bottom: 30,
                      child: IgnorePointer(
                        child: Container(
                          width: 72,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            formatDuration(_at(bubbleFraction)),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.position,
    required this.buffer,
    required this.hover,
    required this.grow,
    required this.active,
    required this.bufferColor,
    required this.inactive,
    required this.thumb,
  });

  final double position;
  final double buffer;
  final double? hover;
  final double grow;
  final Color active;
  final Color bufferColor;
  final Color inactive;
  final Color thumb;

  static const trackHeight = 6.0;
  static const gap = 5.0;
  static const thumbWidth = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final x = position * size.width;
    final radius = const Radius.circular(trackHeight / 2);
    void bar(double from, double to, Color color) {
      if (to - from <= 0.5) return;
      canvas.drawRRect(
        RRect.fromLTRBR(from, cy - trackHeight / 2, to, cy + trackHeight / 2, radius),
        Paint()..color = color,
      );
    }

    final leftEnd = math.max(0.0, x - gap);
    final rightStart = math.min(size.width, x + gap);
    bar(0, leftEnd, active);
    bar(rightStart, size.width, inactive);
    final bufferEnd = buffer * size.width;
    if (bufferEnd > rightStart) bar(rightStart, bufferEnd, bufferColor);

    final h = trackHeight + (trackHeight * 2.5) * grow;
    canvas.drawRRect(
      RRect.fromLTRBR(x - thumbWidth / 2, cy - h / 2, x + thumbWidth / 2, cy + h / 2, const Radius.circular(8)),
      Paint()..color = thumb,
    );
    final hv = hover;
    if (hv != null) {
      final hx = hv * size.width;
      canvas.drawRRect(
        RRect.fromLTRBR(hx - 1, cy - trackHeight, hx + 1, cy + trackHeight, const Radius.circular(1)),
        Paint()..color = thumb.withValues(alpha: 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.position != position || old.buffer != buffer || old.hover != hover || old.grow != grow || old.thumb != thumb;
}
