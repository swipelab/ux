package io.swipelab.ux

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/// `ux/window/events`. Reports app foreground / background as host-focus
/// state — emits {"type":"focus","focused":Bool} on `ProcessLifecycleOwner`
/// ON_START / ON_STOP. The Apple counterpart is `WindowPlugin.swift`
/// (NSApplication active/resign); together they back Dart's `XWindow`.
class WindowPlugin : NativePlugin, EventChannel.StreamHandler {
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

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
        ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ProcessLifecycleOwner.get().lifecycle.removeObserver(observer)
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
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

    private fun emitFocus(focused: Boolean) {
        eventSink?.success(mapOf("type" to "focus", "focused" to focused))
    }
}
