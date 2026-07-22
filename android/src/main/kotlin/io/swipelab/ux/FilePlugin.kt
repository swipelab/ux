package io.swipelab.ux

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

class FilePlugin : NativePlugin, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private var methodChannel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    /// Active pick request — set when [handlePick] launches the picker,
    /// cleared in [onActivityResult]. Reentrancy is rejected.
    private var pendingPickResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/file").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        // If the activity tears down with a request still in flight, settle
        // it cleanly rather than leaking the Result.
        pendingPickResult?.success(null)
        pendingPickResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "share" -> handleShare(call, result)
            "open" -> handleOpen(call, result)
            "pick" -> handlePick(call, result)
            // No file-manager equivalent that's reliable across OEMs.
            "showInFolder" -> result.success(false)
            // Android URI permissions, once persisted, don't need a per-read
            // begin/end cycle — these are no-ops for API symmetry.
            "beginScopedAccess" -> {
                val path = call.argument<String>("path")
                if (path != null) result.success(mapOf("path" to path)) else result.success(null)
            }
            "endScopedAccess" -> result.success(null)
            "videoThumbnail" -> handleVideoThumbnail(call, result)
            "videoThumbnails" -> handleVideoThumbnails(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleShare(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("no_context", "no application context", null)
        val act = activity ?: return result.error("no_activity", "plugin not attached to an activity", null)
        val path = call.argument<String>("path")
            ?: return result.error("bad_args", "path is required", null)
        val title = call.argument<String>("title")
        val mimeType = call.argument<String>("mimeType")

        val authority = "${ctx.packageName}.ux.fileprovider"
        val uri = try {
            FileProvider.getUriForFile(ctx, authority, File(path))
        } catch (e: IllegalArgumentException) {
            return result.error("bad_path", "file is outside FileProvider paths: ${e.message}", null)
        }

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType ?: "*/*"
            putExtra(Intent.EXTRA_STREAM, uri)
            title?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        val chooser = Intent.createChooser(intent, title).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        act.startActivity(chooser)
        result.success(true)
    }

    private fun handleOpen(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("no_context", "no application context", null)
        val act = activity ?: return result.error("no_activity", "plugin not attached to an activity", null)
        val path = call.argument<String>("path")
            ?: return result.error("bad_args", "path is required", null)
        val mimeType = inferMime(call.argument<String>("mimeType"), path)

        val authority = "${ctx.packageName}.ux.fileprovider"
        val uri = try {
            FileProvider.getUriForFile(ctx, authority, File(path))
        } catch (e: IllegalArgumentException) {
            return result.error("bad_path", "file is outside FileProvider paths: ${e.message}", null)
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            act.startActivity(intent)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun handlePick(call: MethodCall, result: MethodChannel.Result) {
        val act = activity
            ?: return result.error("no_activity", "plugin not attached to an activity", null)
        if (pendingPickResult != null) {
            return result.error(
                "in_progress", "a pick request is already in progress", null
            )
        }
        val mimeTypes = (call.argument<List<*>>("mimeTypes"))
            ?.filterIsInstance<String>()
            ?.takeIf { it.isNotEmpty() }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes != null && mimeTypes.size == 1) mimeTypes[0] else "*/*"
            if (mimeTypes != null && mimeTypes.size > 1) {
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingPickResult = result
        try {
            act.startActivityForResult(intent, REQUEST_CODE_PICK)
        } catch (e: ActivityNotFoundException) {
            pendingPickResult = null
            result.error("no_picker", "no document picker available: ${e.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_PICK) return false
        val r = pendingPickResult ?: return true
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK) {
            r.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            r.success(null)
            return true
        }
        val ctx = context
        if (ctx == null) {
            r.error("no_context", "lost application context", null)
            return true
        }
        // Persist the URI grant so we can resolve the original later
        // (e.g. across cold restarts). Best-effort — some providers (notably
        // ones without `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` in the
        // returned intent) reject this; the cached copy still works.
        try {
            ctx.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // No persistable grant — proceed with cache copy only.
        }
        try {
            val picked = copyUriToCache(ctx, uri)
            r.success(picked)
        } catch (e: Throwable) {
            r.error("copy_failed", "could not stream-copy URI to cache: ${e.message}", null)
        }
        return true
    }

    /// Stream-copies the [uri]'s content (an SAF document) to a fresh file
    /// in `cacheDir/ux_pick/`. Returns a map ready for the platform-channel
    /// reply. Crucially, the bytes never live in JVM heap — they flow
    /// `InputStream → 8KB buffer → FileOutputStream`.
    private fun copyUriToCache(ctx: Context, uri: Uri): Map<String, Any?> {
        val resolver = ctx.contentResolver
        var displayName: String? = null
        var size: Long? = null
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null, null, null,
        )?.use { c ->
            if (c.moveToFirst()) {
                val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIdx >= 0 && !c.isNull(nameIdx)) displayName = c.getString(nameIdx)
                val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIdx >= 0 && !c.isNull(sizeIdx)) size = c.getLong(sizeIdx)
            }
        }
        val safeName = (displayName ?: "picked").replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val mimeType = resolver.getType(uri)

        val dir = File(ctx.cacheDir, "ux_pick").apply { mkdirs() }
        val out = File(dir, "${System.currentTimeMillis()}_$safeName")

        var copied = 0L
        resolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "openInputStream returned null for $uri" }
            FileOutputStream(out).use { output ->
                val buf = ByteArray(8 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    output.write(buf, 0, n)
                    copied += n
                }
            }
        }

        return mapOf(
            "path" to out.absolutePath,
            "name" to displayName,
            "mimeType" to mimeType,
            "size" to (size ?: copied),
            // This `path` is an app-owned temp copy under cacheDir/ux_pick (an
            // SAF content:// source can't be opened by dart:io directly). The
            // Dart side treats such a source as ephemeral — promoting its bytes
            // into a managed cache after upload rather than referencing the
            // soon-cleared, non-externally-openable temp in place.
            "isTemporaryCopy" to true,
            // The "bookmark" on Android is the original SAF URI as UTF-8
            // bytes — kept for symmetry with macOS/iOS scoped bookmarks
            // and so callers can re-resolve the source if a future code
            // path needs it (read via ContentResolver).
            "bookmark" to uri.toString().toByteArray(Charsets.UTF_8),
        )
    }

    private fun handleVideoThumbnail(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.error("bad_args", "path is required", null)
        val atMs = (call.argument<Number>("atMs") ?: 0).toLong()
        val maxWidth = (call.argument<Number>("maxWidth") ?: 320).toInt()

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            // OPTION_CLOSEST_SYNC is fastest — picks the nearest keyframe.
            // For atMs=0 this is the first frame, which is what callers
            // typically want for a thumbnail.
            val frame = retriever.getFrameAtTime(
                atMs * 1000L, // µs
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            )
            if (frame == null) {
                result.success(null)
                return
            }
            val scaled = scaleBitmap(frame, maxWidth)
            try {
                val baos = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.PNG, 100, baos)
                result.success(
                    mapOf<String, Any?>(
                        "png" to baos.toByteArray(),
                        "width" to scaled.width,
                        "height" to scaled.height,
                    ),
                )
            } finally {
                if (scaled !== frame) scaled.recycle()
                frame.recycle()
            }
        } catch (e: Throwable) {
            result.error("decode_failed", "could not extract frame: ${e.message}", null)
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    /// Batch variant for the video trim scrubber: one native
    /// round-trip for the whole thumbnail strip, decoded off the main
    /// thread. Per-frame failures come back as null entries, in
    /// `timestampsMs` order.
    private fun handleVideoThumbnails(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.error("bad_args", "path is required", null)
        val timestampsMs = call.argument<List<Number>>("timestampsMs")
            ?: return result.error("bad_args", "timestampsMs is required", null)
        val maxWidth = (call.argument<Number>("maxWidth") ?: 128).toInt()
        val main = Handler(Looper.getMainLooper())

        Thread {
            val reply = ArrayList<Any?>(timestampsMs.size)
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                for (ms in timestampsMs) {
                    val entry: Map<String, Any?>? = try {
                        val frame = retriever.getFrameAtTime(
                            ms.toLong() * 1000L,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        )
                        if (frame == null) {
                            null
                        } else {
                            val scaled = scaleBitmap(frame, maxWidth)
                            try {
                                val baos = ByteArrayOutputStream()
                                scaled.compress(Bitmap.CompressFormat.PNG, 100, baos)
                                mapOf<String, Any?>(
                                    "png" to baos.toByteArray(),
                                    "width" to scaled.width,
                                    "height" to scaled.height,
                                )
                            } finally {
                                if (scaled !== frame) scaled.recycle()
                                frame.recycle()
                            }
                        }
                    } catch (_: Throwable) {
                        null
                    }
                    reply.add(entry)
                }
                main.post { result.success(reply) }
            } catch (e: Throwable) {
                main.post { result.error("decode_failed", "could not open video: ${e.message}", null) }
            } finally {
                try { retriever.release() } catch (_: Throwable) {}
            }
        }.start()
    }

    /// Scales [bitmap] so its longer edge equals [maxWidth] while
    /// preserving aspect ratio. Returns the original if already small enough.
    private fun scaleBitmap(bitmap: Bitmap, maxWidth: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        val longEdge = maxOf(w, h)
        if (longEdge <= maxWidth) return bitmap
        val scale = maxWidth.toFloat() / longEdge
        val outW = (w * scale).toInt().coerceAtLeast(1)
        val outH = (h * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(bitmap, outW, outH, true)
    }

    private fun inferMime(supplied: String?, path: String): String {
        if (!supplied.isNullOrBlank() && supplied != "application/octet-stream") {
            return supplied
        }
        val dot = path.lastIndexOf('.')
        val ext = if (dot in 0 until path.length - 1) path.substring(dot + 1).lowercase() else ""
        if (ext.isNotEmpty()) {
            val guessed = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            if (!guessed.isNullOrBlank()) return guessed
            if (ext in textExtensions) return "text/plain"
        }
        return supplied ?: "*/*"
    }

    companion object {
        private const val REQUEST_CODE_PICK = 0xC51 // arbitrary, namespaced

        private val textExtensions = setOf(
            "dart", "swift", "kt", "kts", "java", "scala", "groovy",
            "py", "rb", "php", "pl", "sh", "bash", "zsh", "fish",
            "ts", "tsx", "jsx", "mjs", "cjs",
            "go", "rs", "c", "h", "cpp", "hpp", "cc", "hh", "m", "mm",
            "lua", "tcl", "r", "ex", "exs", "elm", "hs", "clj", "cljs", "scm",
            "proto", "thrift", "sql",
            "yml", "yaml", "toml", "ini", "conf", "cfg", "env", "properties",
            "gradle", "lock", "diff", "patch",
            "md", "markdown", "log", "txt",
        )
    }
}
