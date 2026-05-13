import 'package:flutter/widgets.dart';

import 'camera.dart' show UxCameraController, UxCameraLens, UxCameraValue;

/// Renders the live preview for [controller] into a [Texture]. Sizes
/// itself to the parent — wrap in `AspectRatio` / `FittedBox` / `Hero`
/// to control framing.
///
/// While the controller is not yet initialized, this falls back to a
/// transparent placeholder. The widget rebuilds on every
/// `UxCameraValue` change, so once the native session starts
/// producing frames the texture appears automatically.
///
/// Front-camera preview is auto-mirrored here (the analog of
/// telegram-iOS's `CameraPreviewView.mirroring` property), so the
/// recorded MP4 + captured JPEG carry the raw sensor feed while the
/// on-screen preview still reads as a natural mirror to the user.
class UxCameraPreview extends StatelessWidget {
  const UxCameraPreview({super.key, required this.controller});

  final UxCameraController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UxCameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final id = controller.textureId;
        if (id == null) return SizedBox.expand();
        final mirror = value.description.lens == UxCameraLens.front;
        final texture = Texture(textureId: id);
        return mirror
            ? Transform.flip(flipX: true, child: texture)
            : texture;
      },
    );
  }
}
