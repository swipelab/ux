import 'package:flutter/widgets.dart';

/// Reports whenever its subtree's size changes, on mount and thereafter.
class Measured extends StatefulWidget {
  /// Binds the subtree to watch and the callback it reports through.
  const Measured({
    required this.child,
    this.onSize,
    super.key,
  });

  /// The subtree whose size is watched.
  final Widget child;

  /// Called on mount and after every size change.
  final VoidCallback? onSize;

  @override
  State<Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<Measured> {
  @override
  void initState() {
    super.initState();
    report();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: handleSizeChanged,
      child: SizeChangedLayoutNotifier(
        child: widget.child,
      ),
    );
  }

  void report() {
    widget.onSize?.call();
  }

  bool handleSizeChanged(SizeChangedLayoutNotification notification) {
    report();
    return false;
  }
}
