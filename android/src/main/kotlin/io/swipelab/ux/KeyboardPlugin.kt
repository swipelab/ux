package io.swipelab.ux

import android.app.Activity
import android.graphics.Insets
import android.os.Build
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class KeyboardPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var methodChannel: MethodChannel? = null
    private var activity: Activity? = null
    private var windowFocusListener: ViewTreeObserver.OnWindowFocusChangeListener? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/keyboard").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enableInteractiveDismiss" -> result.success(null)
            "disableInteractiveDismiss" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        setupInsetsCallback()
        setupWindowFocusListener()
    }

    override fun onDetachedFromActivity() {
        teardownWindowFocusListener()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        setupInsetsCallback()
        setupWindowFocusListener()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        teardownWindowFocusListener()
        activity = null
    }

    /// Reports window-focus changes to Dart via the `onWindowFocused` method.
    /// Needed because Flutter's `TextField(autofocus: true)` at cold start
    /// fires before the Activity window has native focus, so its `TextInput.show`
    /// is ignored ("view not served"). Dart listens and re-requests focus once
    /// the window is focused, at which point the IME reliably appears.
    private fun setupWindowFocusListener() {
        val decor = activity?.window?.decorView ?: return
        val listener = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
            if (hasFocus) {
                methodChannel?.invokeMethod("onWindowFocused", null)
            }
        }
        decor.viewTreeObserver.addOnWindowFocusChangeListener(listener)
        windowFocusListener = listener
    }

    private fun teardownWindowFocusListener() {
        val listener = windowFocusListener ?: return
        activity?.window?.decorView?.viewTreeObserver?.removeOnWindowFocusChangeListener(listener)
        windowFocusListener = null
    }

    private fun setupInsetsCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val view = activity?.window?.decorView ?: return

        // Catch inset changes that don't trigger animations (e.g., emoji keyboard resize)
        view.viewTreeObserver.addOnGlobalLayoutListener {
            val insets = view.rootWindowInsets?.getInsets(WindowInsets.Type.ime()) ?: Insets.NONE
            val density = view.resources.displayMetrics.density
            val height = insets.bottom.toDouble() / density

            if (height != KeyboardBridge.nGetSystemHeight()) {
                KeyboardBridge.nSetSystemHeight(height)
                KeyboardBridge.nSetHeight(height)
            }
        }

        view.setWindowInsetsAnimationCallback(object : WindowInsetsAnimation.Callback(DISPATCH_MODE_STOP) {
            override fun onPrepare(animation: WindowInsetsAnimation) {}

            override fun onStart(
                animation: WindowInsetsAnimation,
                bounds: WindowInsetsAnimation.Bounds
            ): WindowInsetsAnimation.Bounds {
                val insets = view.rootWindowInsets?.getInsets(WindowInsets.Type.ime()) ?: Insets.NONE
                val density = view.resources.displayMetrics.density
                val targetHeight = insets.bottom.toDouble() / density

                KeyboardBridge.nSetSystemHeight(targetHeight)

                val duration = animation.durationMillis / 1000.0
                KeyboardBridge.nSetAnim(targetHeight, duration)

                return bounds
            }

            override fun onProgress(
                insets: WindowInsets,
                runningAnimations: MutableList<WindowInsetsAnimation>
            ): WindowInsets {
                val imeInsets = insets.getInsets(WindowInsets.Type.ime())
                val density = view.resources.displayMetrics.density
                val height = imeInsets.bottom.toDouble() / density

                KeyboardBridge.nSetHeight(height)

                return insets
            }

            override fun onEnd(animation: WindowInsetsAnimation) {
                val insets = view.rootWindowInsets?.getInsets(WindowInsets.Type.ime()) ?: Insets.NONE
                val density = view.resources.displayMetrics.density
                val height = insets.bottom.toDouble() / density

                KeyboardBridge.nSetHeight(height)

                if (height <= 0) {
                    KeyboardBridge.nSetSystemHeight(0.0)
                }
            }
        })
    }
}
