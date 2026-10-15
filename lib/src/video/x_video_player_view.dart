import 'package:flutter/widgets.dart';

import 'x_video_player.dart' show XVideoPlayerController, XVideoPlayerValue;

/// Renders the active frame of [controller] into the parent's box.
/// Sizes itself to the parent — wrap in `AspectRatio` / `FittedBox` /
/// `Hero` to control framing.
///
/// Single render path: a Flutter [Texture] widget over the texture
/// the native side hands back at `create()` time. Android feeds the
/// texture from an [`ExoPlayer`] via a `SurfaceTexture`; Apple feeds
/// it from `AVPlayerItemVideoOutput`; Windows from the Media Engine's
/// frame server through a DXGI shared texture. Because the rendered
/// content lives inside Flutter's compositor:
///
///   - gallery hero / dismiss animations stay buttery
///   - `RenderRepaintBoundary.toImage` (the gallery's `snapshot`
///     mechanism) sees the actual frame and can freeze it across
///     transitions
///   - no per-frame `ImageReader` round-trip — scrub latency stays at
///     codec-seek speed
///
/// Codec crop is handled native-side: Media3's
/// `DefaultVideoFrameProcessor` (Android) re-applies the codec's crop
/// rect downstream of the broken Huawei `SurfaceTexture` transform
/// matrix, so the green right-edge artifact never reaches Flutter's
/// sampler. Apple's `AVPlayerItemVideoOutput` and the Media Engine's
/// frame transfer (Windows) are crop-correct by construction.
class XVideoPlayerView extends StatelessWidget {
  /// Binds the player whose frames fill the view.
  const XVideoPlayerView({super.key, required this.controller});

  /// The player this view renders.
  final XVideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<XVideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (!value.isInitialized) return SizedBox.expand();
        final textureId = controller.textureId;
        if (textureId == null) return SizedBox.expand();
        Widget child = Texture(textureId: textureId);
        // Apple's `AVPlayerItemVideoOutput` hands us `CVPixelBuffer`s in
        // the track's stored orientation — the video track's
        // `preferredTransform` rotation is NOT applied. The native side
        // reports the rotation as quarter-turns; we apply it here so
        // the rendered frame reads upright. Android and Windows always
        // report 0 because the codec + GLES blit, and the Media Engine,
        // handle rotation upstream of Flutter.
        final turns = value.rotationQuarterTurns;
        if (turns != 0) {
          child = RotatedBox(quarterTurns: turns, child: child);
        }
        return child;
      },
    );
  }
}
