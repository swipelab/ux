package io.swipelab.ux.screen

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.swipelab.ux.NativePlugin

/// `ux/screen_sources` on Android, where a capture is consent-driven: the
/// system surface both asks and chooses, so nothing is enumerated and the
/// channel serves the OS floor plus the [ScreenShareService] bracket. The
/// Apple counterpart is `ScreenSourcesPlugin.swift`, which serves the picker
/// snapshot instead.
class ScreenSourcesPlugin : NativePlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ux/screen_sources").also {
            it.setMethodCallHandler { call, result -> handle(context, call, result) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            "startShare" -> startShare(context, call, result)
            "stopShare" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ScreenShareService.stop(context)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startShare(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return result.error("unsupported", "Android 10 or newer", null)
        }
        val title = call.argument<String>("notificationTitle")
        if (title.isNullOrEmpty()) {
            return result.error(
                "invalid_response",
                "notificationTitle: expected a non-empty String",
                null,
            )
        }
        ScreenShareService.start(
            context,
            title,
            call.argument<String>("notificationText"),
        ) { failure ->
            if (failure == null) result.success(null)
            else result.error(failure.code, failure.message, null)
        }
    }
}
