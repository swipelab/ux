import 'package:flutter/widgets.dart';

/// Per-digit "slot-reel" count display. Each digit column animates
/// independently when its value changes; an `AnimatedSize` handles the
/// row growing / shrinking when the digit count itself changes (e.g.
/// `9 → 10`). Right-aligned so the ones-place stays put while leading
/// digits add or drop on the left.
class CountOdometer extends StatelessWidget {
  /// Shows [count] in [style].
  const CountOdometer({
    super.key,
    required this.count,
    required this.style,
    this.duration = const Duration(milliseconds: 300),
    this.curve = Curves.easeOutCubic,
  });

  /// The number shown.
  final int count;

  /// Style of every digit.
  final TextStyle style;

  /// Length of a digit's roll and of the row's resize.
  final Duration duration;

  /// Curve of both.
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final digits = '$count'.split('');
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < digits.length; i++)
            _OdometerDigit(
              // Position-from-right — keeps the ones-place matched
              // across count changes so `9 → 10` rolls "9" → "0" in
              // place while a fresh "1" column mounts on the left.
              key: ValueKey<int>(digits.length - 1 - i),
              digit: digits[i],
              style: style,
              duration: duration,
              curve: curve,
            ),
        ],
      ),
    );
  }
}

class _OdometerDigit extends StatefulWidget {
  const _OdometerDigit({
    super.key,
    required this.digit,
    required this.style,
    required this.duration,
    required this.curve,
  });

  final String digit;
  final TextStyle style;
  final Duration duration;
  final Curve curve;

  @override
  State<_OdometerDigit> createState() => _OdometerDigitState();
}

class _OdometerDigitState extends State<_OdometerDigit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  String? _previous;

  @override
  void initState() {
    super.initState();
    // Settled on mount — the very first digit doesn't roll. Container
    // affordances (parent fade/scale on first appearance) are the
    // correct surface for "thing arrived".
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(_OdometerDigit old) {
    super.didUpdateWidget(old);
    if (widget.duration != old.duration) _ctrl.duration = widget.duration;
    if (old.digit != widget.digit) {
      _previous = old.digit;
      _ctrl.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = (widget.style.fontSize ?? 14).toDouble();
    return ClipRect(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = widget.curve.transform(_ctrl.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              if (_previous != null && t < 1.0)
                Transform.translate(
                  offset: Offset(0, -t * h),
                  child: Opacity(
                    opacity: 1 - t,
                    child: Text(_previous!, style: widget.style),
                  ),
                ),
              Transform.translate(
                offset: Offset(0, (1 - t) * h),
                child: Opacity(
                  opacity: t,
                  child: Text(widget.digit, style: widget.style),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
