import 'package:flutter/cupertino.dart';

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/touch.dart';

/// Compose-page editor entry-points: crop, draw, aspect-ratio. The host
/// (e.g. `ComposePage`) replaces this bar with the active editor's
/// own controls strip while a tool is mounted. Crop, draw and aspect-ratio
/// without a callback show dimmed and take no press; confirm shows only with
/// [onConfirm].
class MediaCommandsBar extends StatelessWidget {
  /// Binds each tool to its callback.
  const MediaCommandsBar({
    super.key,
    this.onCrop,
    this.onDraw,
    this.onAspectRatio,
    this.onConfirm,
  });

  /// Opens the crop tool.
  final VoidCallback? onCrop;

  /// Opens the draw tool.
  final VoidCallback? onDraw;

  /// Opens the aspect-ratio choices.
  final VoidCallback? onAspectRatio;

  /// Confirms the edits.
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.md, vertical: space.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox.shrink(),
          _CommandButton(
            icon: CupertinoIcons.crop,
            onPress: onCrop,
          ),
          _CommandButton(
            icon: CupertinoIcons.hand_draw,
            onPress: onDraw,
          ),
          _CommandButton(
            icon: CupertinoIcons.plus_slash_minus,
            onPress: onAspectRatio,
          ),
          onConfirm == null
              ? const SizedBox.shrink()
              : _CommandButton(
                  icon: CupertinoIcons.check_mark,
                  onPress: onConfirm,
                ),
        ],
      ),
    );
  }
}

class _CommandButton extends StatelessWidget {
  const _CommandButton({required this.icon, this.onPress});

  final IconData icon;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final fade = onPress == null ? 0.35 : 1.0;
    return Touch(
      fade: 0.5,
      onPress: onPress,
      padding: EdgeInsets.all(space.md),
      child: Opacity(
        opacity: fade,
        child: Icon(icon, color: colors.onMedia, size: 24),
      ),
    );
  }
}
