package io.swipelab.ux.video

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector

/// Renderer factory configured for Banlu. Two non-default tweaks:
///
///   - `setEnableDecoderFallback(true)` — Media3's default refuses to
///     fall back if the primary decoder fails to start. On Huawei
///     EMUI (Mate 20 Pro / LYA-L29 / API 29) the hardware AVC decoder
///     `OMX.hisi.video.decoder.avc` fails codec start; without
///     fallback the surface stays black.
///   - `MediaCodecSelector` deprioritises `OMX.hisi.*` so Media3
///     picks the working software decoder first
///     (`c2.android.avc.decoder` on the affected device). The
///     hardware decoder stays as a last-resort option for devices
///     where it works correctly.
@UnstableApi
internal object Renderers {
  fun build(context: Context): RenderersFactory {
    return DefaultRenderersFactory(context)
      .setEnableDecoderFallback(true)
      .setMediaCodecSelector { mimeType, requiresSecure, requiresTunneling ->
        val infos = MediaCodecSelector.DEFAULT.getDecoderInfos(
          mimeType, requiresSecure, requiresTunneling,
        )
        val ok = ArrayList<MediaCodecInfo>(infos.size)
        val broken = ArrayList<MediaCodecInfo>()
        for (info in infos) {
          if (info.name.startsWith("OMX.hisi.")) broken.add(info) else ok.add(info)
        }
        ok.addAll(broken)
        ok
      }
  }
}
