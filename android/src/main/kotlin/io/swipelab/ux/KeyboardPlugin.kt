package io.swipelab.ux

import android.app.Activity
import android.graphics.Insets
import android.os.Build
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class KeyboardPlugin : NativePlugin, MethodChannel.MethodCallHandler {
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
        val view = activity?.window?.decorView ?: return

        // Layout-driven changes (e.g. emoji keyboard resize on R+ where the
        // animation callback doesn't fire).
        view.viewTreeObserver.addOnGlobalLayoutListener {
            val rootInsets = view.rootWindowInsets ?: return@addOnGlobalLayoutListener
            publishImeHeight(view, rootInsets)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // No WindowInsetsAnimation API on pre-R. The global-layout listener
            // catches IME-open (activity resizes) but on some OEMs (notably
            // EMUI 10) IME-hide dispatches new insets without a follow-up
            // layout — leaving that listener silent. setOnApplyWindowInsetsListener
            // fires on every inset dispatch, so it catches both ends.
            view.setOnApplyWindowInsetsListener { v, insets ->
                publishImeHeight(v, insets)
                v.onApplyWindowInsets(insets)
            }
            return
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

    private fun publishImeHeight(view: android.view.View, insets: WindowInsets) {
        val density = view.resources.displayMetrics.density
        val imePx: Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // TODO: on devices where a fixed nav bar stacks below the IME
            // (e.g. HarmonyOS R+ with 3-button nav), Type.ime().bottom may
            // exclude the nav-bar strip — same shape as the pre-R bug below.
            // Verify when an R+ Huawei device is available; if confirmed,
            // add Type.navigationBars() when the IME is visible.
            insets.getInsets(WindowInsets.Type.ime()).bottom
        } else {
            // Report the total bottom-occluded area when the IME is open, so
            // callers can max(keyboard.height, viewPadding.bottom) without
            // adding the safe-area inset separately — matching iOS, where the
            // reported keyboard frame already covers the home-indicator strip.
            //
            // systemWindowInsetBottom = nav bar + IME (when open) or just nav bar
            // stableInsetBottom       = nav bar (stable, doesn't animate in/out)
            @Suppress("DEPRECATION")
            val systemBottom = insets.systemWindowInsetBottom
            @Suppress("DEPRECATION")
            val stableBottom = insets.stableInsetBottom
            if (systemBottom > stableBottom) systemBottom else 0
        }
        val height = imePx.toDouble() / density

        if (height != KeyboardBridge.nGetSystemHeight()) {
            KeyboardBridge.nSetSystemHeight(height)
            KeyboardBridge.nSetHeight(height)
        }
    }
}
