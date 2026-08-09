import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';

import 'camera.dart' show XCameraController, XCameraLens, XCameraValue;

/// Renders the live preview for [controller] into a [Texture]. Sizes
/// itself to the parent — wrap in `AspectRatio` / `FittedBox` / `Hero`
/// to control framing.
///
/// While the controller is not yet initialized, this falls back to a
/// transparent placeholder. The widget rebuilds on every
/// `XCameraValue` change, so once the native session starts
/// producing frames the texture appears automatically.
///
/// Front-camera preview is auto-mirrored here (the analog of
/// telegram-iOS's `CameraPreviewView.mirroring` property), so the
/// recorded MP4 + captured JPEG carry the raw sensor feed while the
/// on-screen preview still reads as a natural mirror to the user.
class XCameraPreview extends StatelessWidget {
  /// Binds the session whose frames fill the preview.
  const XCameraPreview({super.key, required this.controller});

  /// The session this preview renders.
  final XCameraController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<XCameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final id = controller.textureId;
        if (id == null) return SizedBox.expand();
        Widget child = Texture(textureId: id);
        // Order matters: rotate first (sensor → screen frame), then
        // mirror in screen space. Reversing them would mirror across
        // an axis that's still aligned with the sensor.
        final turns = value.previewRotationQuarterTurns;
        if (turns != 0) {
          child = RotatedBox(quarterTurns: turns, child: child);
        }
        // iOS only: AVCaptureConnection.isVideoMirrored is `false` on
        // the data output (capture stays raw), so Flutter mirrors the
        // selfie preview here. On Android, CameraX's Preview use case
        // builds a SurfaceTexture transform matrix that already
        // mirrors the front cam — adding our own flip on top
        // double-mirrors and, when the device tilts, makes CameraX's
        // counter-rotation appear to double in the same direction as
        // the phone tilt (because we're flipping the axis CameraX
        // rotated around).
        if (defaultTargetPlatform != TargetPlatform.android &&
            value.description.lens == XCameraLens.front) {
          child = Transform.flip(flipX: true, child: child);
        }
        return child;
      },
    );
  }
}
