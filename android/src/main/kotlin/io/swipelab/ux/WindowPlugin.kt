package io.swipelab.ux

import android.view.WindowManager
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// `ux/window` + `ux/window/events`. The event channel reports app foreground
/// / background as host-focus state — emits {"type":"focus","focused":Bool} on
/// `ProcessLifecycleOwner` ON_START / ON_STOP. The method channel serves
/// `keepAwake`, FLAG_KEEP_SCREEN_ON on the activity window: the flag holds the
/// screen only while that window is visible, and goes away with the activity
/// or the engine, whichever detaches first. The Apple counterpart is
/// `WindowPlugin.swift`; together they back Dart's `XWindow`.
class WindowPlugin : NativePlugin, EventChannel.StreamHandler,
    MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activity: android.app.Activity? = null

    /// The hold Dart asked for, applied to whichever activity window is
    /// attached — a configuration change swaps the window, not the hold.
    private var awake = false

    /// ProcessLifecycleOwner delivers ON_START/ON_STOP on the main thread,
    /// which is also where EventSink.success must run — no Handler bounce.
    private val observer = LifecycleEventObserver { _, event ->
        when (event) {
            Lifecycle.Event.ON_START -> emitFocus(true)
            Lifecycle.Event.ON_STOP -> emitFocus(false)
            else -> Unit
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ec = EventChannel(binding.binaryMessenger, "ux/window/events")
        ec.setStreamHandler(this)
        eventChannel = ec
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/window").also {
            it.setMethodCallHandler(this)
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ProcessLifecycleOwner.get().lifecycle.removeObserver(observer)
        awake = false
        applyAwake()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        applyAwake()
    }

    override fun onDetachedFromActivity() {
        activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        activity = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Seed the current state so a late subscriber gets the right value
        // immediately instead of waiting for the next ON_START / ON_STOP.
        val foreground = ProcessLifecycleOwner.get().lifecycle.currentState
            .isAtLeast(Lifecycle.State.STARTED)
        emitFocus(foreground)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "keepAwake" -> {
                val enabled = call.argument<Boolean>("enabled")
                    ?: return result.error("bad_args", "enabled required", null)
                awake = enabled
                applyAwake()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun applyAwake() {
        val window = activity?.window ?: return
        if (awake) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun emitFocus(focused: Boolean) {
        eventSink?.success(mapOf("type" to "focus", "focused" to focused))
    }
}
