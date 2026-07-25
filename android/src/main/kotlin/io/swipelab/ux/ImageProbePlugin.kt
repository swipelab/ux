package io.swipelab.ux

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Describes an image file for `XImageProbe`: upright dimensions and a
/// downscaled PNG, without ever holding the full-resolution bitmap.
///
/// `inJustDecodeBounds` measures from the header alone, and `inSampleSize`
/// decodes a subsampled bitmap — so the allocation follows the *output* size.
/// Decoding a 48-megapixel photo to read its size or make a 200px thumbnail
/// would cost ~190 MB, which is what this exists to avoid.
class ImageProbePlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null

    // Decode is disk + CPU bound; keep it off the platform thread.
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ux-image-probe").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/image_probe").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.error("bad_args", "path is required", null)
        when (call.method) {
            "size" -> worker.execute {
                val size = displaySize(path)
                main.post {
                    result.success(
                        size?.let { mapOf("width" to it.first, "height" to it.second) },
                    )
                }
            }
            "thumbnail" -> {
                val maxLongest = call.argument<Int>("maxLongest") ?: 0
                if (maxLongest <= 0) {
                    return result.error("bad_args", "maxLongest must be > 0", null)
                }
                worker.execute {
                    val thumb = thumbnail(path, maxLongest)
                    main.post { result.success(thumb) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /// Header-only dimensions, EXIF orientation applied.
    private fun displaySize(path: String): Pair<Int, Int>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        return if (quarterTurns(path) % 2 == 1) {
            bounds.outHeight to bounds.outWidth
        } else {
            bounds.outWidth to bounds.outHeight
        }
    }

    private fun thumbnail(path: String, maxLongest: Int): Map<String, Any?>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val turns = quarterTurns(path)
        val sourceWidth = if (turns % 2 == 1) bounds.outHeight else bounds.outWidth
        val sourceHeight = if (turns % 2 == 1) bounds.outWidth else bounds.outHeight

        // Largest power-of-two subsample that still covers the target: the
        // decoder never materialises anything bigger than this.
        var sample = 1
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        while (longest / (sample * 2) >= maxLongest) sample *= 2

        val decoded = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: return null

        val upright = rotate(decoded, turns)
        val scale = maxLongest.toFloat() / maxOf(upright.width, upright.height)
        val scaled = if (scale >= 1f) {
            upright
        } else {
            Bitmap.createScaledBitmap(
                upright,
                (upright.width * scale).toInt().coerceAtLeast(1),
                (upright.height * scale).toInt().coerceAtLeast(1),
                true,
            ).also { if (it !== upright) upright.recycle() }
        }

        val png = ByteArrayOutputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
        val width = scaled.width
        val height = scaled.height
        scaled.recycle()

        return mapOf(
            "sourceWidth" to sourceWidth,
            "sourceHeight" to sourceHeight,
            "width" to width,
            "height" to height,
            "png" to png,
        )
    }

    private fun rotate(bitmap: Bitmap, turns: Int): Bitmap {
        if (turns == 0) return bitmap
        val matrix = Matrix().apply { postRotate(90f * turns) }
        val rotated = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true,
        )
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }

    private fun quarterTurns(path: String): Int = when (
        ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    ) {
        ExifInterface.ORIENTATION_ROTATE_90 -> 1
        ExifInterface.ORIENTATION_ROTATE_180 -> 2
        ExifInterface.ORIENTATION_ROTATE_270 -> 3
        else -> 0
    }
}
