import 'package:ux/src/media/design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ux/camera.dart';

/// `previewSize` from the native side is reported sensor-native
/// (landscape on most cameras). On iOS + Android the data-output /
/// SurfaceTexture transform rotates the buffer to portrait, so we
/// swap dims (shortestSide as width, longestSide as height) to size
/// the inner SizedBox to match. On macOS the desktop camera stays
/// landscape — no rotation applied — so we use the dims as-is.
/// Without that platform check the macOS preview ends up stretching
/// a landscape buffer into a portrait box.
bool get _preferLandscapePreview =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows;

/// The live preview of [controller] over [color], covering its box on mobile
/// and contained on desktop, with [child] on top.
class CameraThumb extends StatelessWidget {
  /// Creates the preview; [color] defaults to black.
  const CameraThumb({
    super.key,
    required this.controller,
    this.child,
    Color? color,
  }) : color = color ?? const Color(0xFF000000);

  /// The camera previewed; [color] alone shows while absent.
  final ValueListenable<XCameraController?> controller;
  /// Drawn over the preview.
  final Widget? child;
  /// Fill behind the preview.
  final Color color;

  @override
  Widget build(BuildContext context) {
    final overlay = child;
    return ColoredBox(
      color: color,
      child: ValueListenableBuilder<XCameraController?>(
        valueListenable: controller,
        builder: (_, ctrl, _) {
          final preview = ctrl == null
              ? SizedBox.expand()
              : ValueListenableBuilder<XCameraValue>(
                  valueListenable: ctrl,
                  builder: (context, value, _) {
                    final previewSize = value.previewSize;
                    final preview = ctrl.buildPreview();
                    // While we wait for the first frame's actual
                    // dimensions (Android CameraX reports them async
                    // via a previewSizeChanged event), let the
                    // Texture fill the parent's 3:4 region so the
                    // preview paints as soon as the first frame
                    // lands rather than staying black until the
                    // event arrives. Aspect may be slightly off for
                    // that first moment; the FittedBox layout below
                    // takes over once previewSize is known.
                    final Widget content;
                    if (previewSize == null || previewSize.isEmpty) {
                      content = preview;
                    } else {
                      // Desktop cameras stay landscape (no buffer
                      // rotation); mobile data outputs rotate to
                      // portrait, so the SizedBox swaps dims there.
                      final w = _preferLandscapePreview
                          ? previewSize.width
                          : previewSize.shortestSide;
                      final h = _preferLandscapePreview
                          ? previewSize.height
                          : previewSize.longestSide;
                      // BoxFit.cover on mobile (camera-app convention
                      // — fill the screen, crop the sensor edges if
                      // the page aspect doesn't match). BoxFit.contain
                      // on desktop where there's plenty of room and
                      // cropping just hides scene content the user
                      // can clearly see they're framing.
                      content = FittedBox(
                        fit: _preferLandscapePreview
                            ? BoxFit.contain
                            : BoxFit.cover,
                        child: SizedBox(
                          width: w,
                          height: h,
                          child: preview,
                        ),
                      );
                    }
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRect(child: content),
                        ?overlay,
                      ],
                    );
                  },
                );

          return AnimatedSwitcher(
            duration: kAnimation,
            child: preview,
          );
        },
      ),
    );
  }
}
