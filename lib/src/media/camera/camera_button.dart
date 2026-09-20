import 'package:ux/src/media/design.dart';
import 'package:flutter/material.dart';
import 'package:ux/src/media/touch.dart';

/// What the shutter button shows.
enum CameraButtonState {
  /// Ready to take a photo.
  photo,

  /// Ready to record a video.
  video,

  /// Recording a video.
  recording,
}

/// The shutter: a ring around a disc that is white for a photo, red for a
/// video, and a small red square while recording.
class CameraButton extends StatelessWidget {
  /// Creates the shutter.
  const CameraButton({
    super.key,
    this.value = CameraButtonState.photo,
    this.onPress,
    this.onLongPress,
  });

  /// What the button shows.
  final CameraButtonState value;
  /// Called on a tap.
  final VoidCallback? onPress;
  /// Called on a long press.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Touch(
      onPress: onPress,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.onMedia, width: 3),
        ),
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          width: 64,
          height: 64,
          child: AnimatedContainer(
            duration: kAnimation,
            margin: EdgeInsets.all(
              value == CameraButtonState.recording ? 18 : 0,
            ),
            decoration: BoxDecoration(
              shape: BoxShape.rectangle,
              color: value == CameraButtonState.photo
                  ? colors.onMedia
                  : colors.onMediaDestructive,
              borderRadius: BorderRadius.circular(
                value == CameraButtonState.recording ? 3 : 32,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
