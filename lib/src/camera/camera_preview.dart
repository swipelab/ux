import 'package:flutter/widgets.dart';

import 'camera.dart' show UxCameraController, UxCameraValue;

/// Renders the live preview for [controller] into a [Texture]. Sizes
/// itself to the parent — wrap in `AspectRatio` / `FittedBox` / `Hero`
/// to control framing.
///
/// While the controller is not yet initialized, this falls back to a
/// transparent placeholder. The widget rebuilds on every
/// `UxCameraValue` change, so once the native session starts
/// producing frames the texture appears automatically.
class UxCameraPreview extends StatelessWidget {
  const UxCameraPreview({super.key, required this.controller});

  final UxCameraController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UxCameraValue>(
      valueListenable: controller,
      builder: (context, _, __) {
        final id = controller.textureId;
        if (id == null) return const SizedBox.expand();
        return Texture(textureId: id);
      },
    );
  }
}
