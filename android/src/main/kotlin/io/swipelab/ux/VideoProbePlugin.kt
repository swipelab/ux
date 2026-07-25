package io.swipelab.ux

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/// Describes a video file in one round-trip for `XVideoProbe`: upright display
/// dimensions, duration, and a poster frame. A single [MediaMetadataRetriever]
/// — no player, no texture registry, no Media3 — so the caller gets a
/// placeholder for a file it never plays.
///
/// A file the retriever can't read as video (no video track, unsupported
/// container, truncated download) reports null, matching what the Apple arm
/// returns for an asset with no video tracks. A file whose *frame* won't
/// decode still reports dimensions and duration, just without a poster.
class VideoProbePlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null

    // Retriever work is disk + decode bound; keep it off the platform thread.
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ux-video-probe").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/video_probe").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> handleProbe(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleProbe(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.error("bad_args", "path is required", null)
        val atMs = call.argument<Number>("atMs")?.toLong() ?: 0L
        // Absent = poster at native resolution.
        val maxWidth = call.argument<Number>("maxWidth")?.toInt()

        try {
            worker.execute {
                val reply = probe(path, atMs, maxWidth)
                main.post { result.success(reply) }
            }
        } catch (e: RejectedExecutionException) {
            main.post { result.error("probe_failed", e.message ?: e.toString(), null) }
        }
    }

    private fun probe(path: String, atMs: Long, maxWidth: Int?): Map<String, Any?>? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val rawWidth = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val rawHeight = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            if (rawWidth == null || rawHeight == null) return null
            // Recordings store their orientation as metadata rather than
            // rotating the encoded frames; a quarter turn transposes the
            // display size the same way the returned frame already is.
            val rotation = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: 0
            val quarterTurn = rotation == 90 || rotation == 270
            return mapOf(
                "width" to if (quarterTurn) rawHeight else rawWidth,
                "height" to if (quarterTurn) rawWidth else rawHeight,
                "durationMs" to (retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_DURATION) ?: 0),
                "png" to poster(retriever, atMs, maxWidth),
            )
        } catch (_: Throwable) {
            return null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    private fun poster(retriever: MediaMetadataRetriever, atMs: Long, maxWidth: Int?): ByteArray? {
        // OPTION_CLOSEST_SYNC lands on the nearest keyframe — for atMs = 0 that
        // is the first frame, which is what a placeholder wants.
        val frame = try {
            retriever.getFrameAtTime(atMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (_: Throwable) {
            null
        } ?: return null
        val scaled = if (maxWidth != null && frame.width > maxWidth) {
            val height = (frame.height.toLong() * maxWidth / frame.width).toInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(frame, maxWidth, height, true)
        } else {
            frame
        }
        try {
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            return out.toByteArray()
        } finally {
            if (scaled !== frame) scaled.recycle()
            frame.recycle()
        }
    }

    private fun MediaMetadataRetriever.intMeta(key: Int): Int? =
        extractMetadata(key)?.toIntOrNull()
}
