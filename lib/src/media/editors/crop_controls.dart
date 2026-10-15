import 'package:ux/src/media/design.dart';
import 'package:flutter/cupertino.dart';
import 'package:ux/src/media/touch.dart';

/// Bottom control row for the crop tool: cancel / rotate-90 / flip /
/// aspect-ratio / submit.
class CropControls extends StatelessWidget {
  /// Binds each control to its callback.
  const CropControls({
    super.key,
    required this.onCancel,
    required this.onRotate,
    required this.onFlip,
    required this.isFlipped,
    required this.onAspectRatio,
    required this.onSubmit,
  });

  /// Leaves the crop tool without applying.
  final VoidCallback onCancel;

  /// Turns the image by 90 degrees.
  final VoidCallback onRotate;

  /// Mirrors the image.
  final VoidCallback onFlip;

  /// Whether the image is mirrored; the flip control shows it.
  final bool isFlipped;

  /// Opens the aspect-ratio choices.
  final VoidCallback onAspectRatio;

  /// Applies the crop.
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.sm, vertical: space.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _Btn(icon: CupertinoIcons.xmark_circle, onPress: onCancel),
          _Btn(icon: CupertinoIcons.rotate_left, onPress: onRotate),
          _Btn(
            icon: CupertinoIcons.triangle_lefthalf_fill,
            tint: isFlipped ? colors.brand : null,
            onPress: onFlip,
          ),
          _Btn(icon: CupertinoIcons.square, onPress: onAspectRatio),
          _Btn(icon: CupertinoIcons.check_mark_circled, onPress: onSubmit),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({required this.icon, required this.onPress, this.tint});

  final IconData icon;
  final VoidCallback onPress;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Touch(
      fade: 0.5,
      onPress: onPress,
      padding: EdgeInsets.all(space.md),
      child: Icon(icon, color: tint ?? colors.onMedia, size: 28),
    );
  }
}
