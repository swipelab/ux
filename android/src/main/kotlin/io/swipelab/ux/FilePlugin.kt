package io.swipelab.ux

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class FilePlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null

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
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "share" -> handleShare(call, result)
            "open" -> handleOpen(call, result)
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
