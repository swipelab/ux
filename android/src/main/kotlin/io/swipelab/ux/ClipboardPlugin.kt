package io.swipelab.ux

import android.content.ClipboardManager
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class ClipboardPlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/clipboard").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readImage" -> handleReadImage(result)
            else -> result.notImplemented()
        }
    }

    private fun handleReadImage(result: MethodChannel.Result) {
        val ctx = context ?: return result.success(null)
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return result.success(null)
        val clip = cm.primaryClip ?: return result.success(null)
        if (clip.itemCount == 0) return result.success(null)

        val uri = clip.getItemAt(0).uri ?: return result.success(null)

        // Don't trust the clip description's MIME — some apps lie. Open
        // the stream and copy whatever bytes the resolver returns; the
        // composer side is happy to send any media-typed file.
        try {
            ctx.contentResolver.openInputStream(uri).use { input ->
                if (input == null) return result.success(null)
                val out = ByteArrayOutputStream()
                input.copyTo(out)
                result.success(out.toByteArray())
            }
        } catch (_: Exception) {
            result.success(null)
        }
    }
}
