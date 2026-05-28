package io.swipelab.ux.video

import android.content.Context
import android.os.Handler
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.VideoRendererEventListener
import io.swipelab.ux.video.ffmpeg.FfmpegLibrary
import io.swipelab.ux.video.ffmpeg.FfmpegSurfaceSizer
import io.swipelab.ux.video.ffmpeg.FfmpegVideoRenderer

/// Renderer factory configured for Banlu.
///
/// Video path is tiered:
///   1. `FfmpegVideoRenderer` — vendored Media3 FFmpeg extension that
///      decodes H.264 with libavcodec and converts YUV→RGB via a GLES2
///      shader. Selected first for any MIME type FFmpeg supports. Has
///      no DPB cap, handles iOS yuvj420p full-range streams that defeat
///      both `c2.hisi.avc.decoder` (EMUI 11 Mate 20 stalls on the first
///      sample after init) and `c2.android.avc.decoder` (Google C2 SW
///      caps output delay at 8 frames; iOS H.264 with `has_b_frames=16`
///      starves the decoder until CCodec's queue timeout). When
///      `libffmpegJNI.so` is missing for the current ABI, FfmpegLibrary
///      returns isAvailable()=false and selection falls through.
///   2. `MediaCodec` path with `setEnableDecoderFallback(true)`. Init
///      failures (EMUI 10 `OMX.hisi.video.decoder.avc`) bounce to the
///      next decoder.
///   3. `MediaCodecSelector` deprioritises every HiSilicon decoder
///      (`OMX.hisi.*` and `c2.hisi.*`) so Media3 picks
///      `c2.android.avc.decoder` ahead of `c2.hisi.avc.decoder` when
///      FFmpeg isn't available. Without this, the EMUI 11 C2 Hisi
///      decoder is chosen and fails after init — which decoder
///      fallback doesn't catch.
@UnstableApi
internal object Renderers {
  fun build(context: Context, surfaceSizer: FfmpegSurfaceSizer): RenderersFactory {
    return object : DefaultRenderersFactory(context) {
      override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
      ) {
        if (FfmpegLibrary.isAvailable()) {
          out.add(
            FfmpegVideoRenderer(
              allowedVideoJoiningTimeMs,
              eventHandler,
              eventListener,
              MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY,
              surfaceSizer,
            ),
          )
        }
        super.buildVideoRenderers(
          context,
          extensionRendererMode,
          mediaCodecSelector,
          enableDecoderFallback,
          eventHandler,
          eventListener,
          allowedVideoJoiningTimeMs,
          out,
        )
      }
    }
      .setEnableDecoderFallback(true)
      .setMediaCodecSelector { mimeType, requiresSecure, requiresTunneling ->
        val infos = MediaCodecSelector.DEFAULT.getDecoderInfos(
          mimeType, requiresSecure, requiresTunneling,
        )
        val ok = ArrayList<MediaCodecInfo>(infos.size)
        val broken = ArrayList<MediaCodecInfo>()
        for (info in infos) {
          val name = info.name.lowercase()
          if (name.startsWith("omx.hisi.") || name.startsWith("c2.hisi.")) {
            broken.add(info)
          } else {
            ok.add(info)
          }
        }
        ok.addAll(broken)
        ok
      }
  }
}
