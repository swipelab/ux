package io.swipelab.ux.camera.effects

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.swipelab.ux.BuildConfig
import io.swipelab.ux.NativePlugin

/**
 * Where the host app hands `ux` its camera stack.
 *
 * ```kotlin
 * CameraEffects.install(MyCameraEffectsBridge())
 * ```
 *
 * With nothing installed, `available()` answers false, `setEffect` answers
 * `integration_unavailable`, and `clear()` remains an idempotent success.
 */
object CameraEffects {
    fun install(bridge: CameraTrackBridging) = service.install(bridge)

    /**
     * Drops the bridge, detaching a live attachment through it and then
     * tearing it down. That attachment is reported failed at this moment
     * rather than at the next command.
     */
    fun uninstall() = service.uninstall()

    val isInstalled: Boolean get() = service.isBridgeInstalled

    internal val cadence = CameraThermalCadence()

    internal val processors = CameraEffectProcessors(cadence)

    internal val composites = CameraCompositeLog(exposes = BuildConfig.DEBUG)

    internal val service = CameraEffectsService(
        processors = processors,
        scheduler = MainLooperScheduler(),
        delivery = MainLooperDelivery(),
        composites = composites,
    )
}

/**
 * `ux/camera_effects` + `ux/camera_effects/events`. Carries commands and
 * status between the channels and [CameraEffectsService], which owns the
 * state and delivers every continuation on the main looper.
 */
class CameraEffectsPlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CameraEffects.cadence.observe(PowerManagerThermalSource(binding.applicationContext))
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/camera_effects")
            .also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, "ux/camera_effects/events")
            .also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CameraEffects.service.teardown()
        CameraEffects.cadence.stop()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events == null) return
        events.success(CameraEffectsWire.encode(CameraEffects.service.currentStatus))
        CameraEffects.service.setStatusObserver { status ->
            events.success(CameraEffectsWire.encode(status))
        }
    }

    override fun onCancel(arguments: Any?) {
        CameraEffects.service.setStatusObserver(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (val decoded = CameraEffectsWire.decode(call.method, call.arguments as? Map<*, *>)) {
            is CameraEffectsDecoding.UnknownMethod -> result.notImplemented()
            is CameraEffectsDecoding.Invalid -> sendError(decoded.failure, result)
            is CameraEffectsDecoding.Request ->
                CameraEffects.service.reply(decoded.request) { reply -> send(reply, result) }
        }
    }

    private fun send(reply: CameraEffectsReply, result: MethodChannel.Result) {
        when (reply) {
            is CameraEffectsReply.Flag -> result.success(reply.value)
            is CameraEffectsReply.Done -> result.success(null)
            is CameraEffectsReply.Failure -> sendError(reply.failure, result)
        }
    }

    private fun sendError(failure: CameraEffectsFailure, result: MethodChannel.Result) {
        result.error(failure.code, failure.message, null)
    }
}
