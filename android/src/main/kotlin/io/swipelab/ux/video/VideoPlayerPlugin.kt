package io.swipelab.ux.video

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import io.swipelab.ux.NativePlugin

/// `ux/video` + `ux/video/events` registrar. Routes channel calls to
/// per-handle [VideoPlayerInstance]s. Mirrors the shape of
/// [io.swipelab.ux.camera.CameraPlugin].
@UnstableApi
class VideoPlayerPlugin :
  NativePlugin,
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler {

  private val main = Handler(Looper.getMainLooper())

  private var context: Context? = null
  private var textureRegistry: TextureRegistry? = null
  private var methodChannel: MethodChannel? = null
  private var eventChannel: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null

  private val instances = mutableMapOf<Int, VideoPlayerInstance>()
  private var nextHandle = 1

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    textureRegistry = binding.textureRegistry

    val mc = MethodChannel(binding.binaryMessenger, "ux/video")
    mc.setMethodCallHandler(this)
    methodChannel = mc

    val ec = EventChannel(binding.binaryMessenger, "ux/video/events")
    ec.setStreamHandler(this)
    eventChannel = ec
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    instances.values.forEach { it.dispose() }
    instances.clear()

    methodChannel?.setMethodCallHandler(null)
    methodChannel = null
    eventChannel?.setStreamHandler(null)
    eventChannel = null
    eventSink = null
    context = null
    textureRegistry = null
  }

  // MARK: - EventChannel

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  // MARK: - MethodChannel

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "create" -> handleCreate(call, result)
      "initialize" -> handleInitialize(call, result)
      "dispose" -> handleDispose(call, result)
      "play" -> handlePlay(call, result)
      "pause" -> handlePause(call, result)
      "seekTo" -> handleSeekTo(call, result)
      "setLooping" -> handleSetLooping(call, result)
      "setVolume" -> handleSetVolume(call, result)
      "setPlaybackSpeed" -> handleSetPlaybackSpeed(call, result)
      else -> result.notImplemented()
    }
  }

  private fun handleCreate(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *>
      ?: return result.error("bad_args", "create", null)
    val uriRaw = args["uri"] as? String
      ?: return result.error("bad_args", "create", null)
    val ctx = context ?: return result.error("no_context", "engine detached", null)
    val registry = textureRegistry
      ?: return result.error("no_context", "no texture registry", null)

    val textureEntry = registry.createSurfaceTexture()
    val handle = nextHandle++
    val instance = VideoPlayerInstance(handle, ctx, textureEntry)
    instance.onEvent = { payload ->
      main.post { eventSink?.success(payload) }
    }
    try {
      instance.setSource(Uri.parse(uriRaw))
    } catch (t: Throwable) {
      instance.dispose()
      return result.error("bad_args", t.localizedMessage, null)
    }
    instances[handle] = instance
    result.success(
      mapOf(
        "handle" to handle,
        "textureId" to instance.textureId,
      ),
    )
  }

  private fun handleInitialize(call: MethodCall, result: MethodChannel.Result) {
    withInstance(call, result) { instance ->
      instance.prepare { prepared ->
        when (prepared) {
          is PrepareResult.Ready -> result.success(
            mapOf(
              "size" to mapOf(
                "width" to prepared.size.width.toDouble(),
                "height" to prepared.size.height.toDouble(),
              ),
              "durationMs" to prepared.durationMs,
              // Android rotation is applied by ExoPlayer's MediaCodec
              // configuration + the SurfaceTexture transform matrix our
              // compositor's GLES blit already honours, so the Flutter
              // `Texture` widget needs no additional rotation.
              "rotationQuarterTurns" to 0,
            ),
          )
          is PrepareResult.Failed -> result.error(
            "decode_failed",
            prepared.error.message ?: "ExoPlayer prepare failed",
            null,
          )
          PrepareResult.Disposed -> result.error(
            "disposed",
            "player disposed before it was ready",
            null,
          )
        }
      }
    }
  }

  private fun handleDispose(call: MethodCall, result: MethodChannel.Result) {
    withInstance(call, result) { instance ->
      instances.remove(instance.handle)
      instance.dispose()
      result.success(null)
    }
  }

  private fun handlePlay(call: MethodCall, result: MethodChannel.Result) {
    withInstance(call, result) { it.play(); result.success(null) }
  }

  private fun handlePause(call: MethodCall, result: MethodChannel.Result) {
    withInstance(call, result) { it.pause(); result.success(null) }
  }

  private fun handleSeekTo(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *>
      ?: return result.error("bad_args", "seekTo", null)
    val pos = (args["positionMs"] as? Number)?.toLong()
      ?: return result.error("bad_args", "seekTo positionMs", null)
    withInstance(call, result) { it.seekTo(pos); result.success(null) }
  }

  private fun handleSetLooping(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *>
      ?: return result.error("bad_args", "setLooping", null)
    val loop = args["loop"] as? Boolean ?: false
    withInstance(call, result) { it.setLooping(loop); result.success(null) }
  }

  private fun handleSetVolume(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *>
      ?: return result.error("bad_args", "setVolume", null)
    val volume = (args["volume"] as? Number)?.toFloat()
      ?: return result.error("bad_args", "setVolume volume", null)
    withInstance(call, result) { it.setVolume(volume); result.success(null) }
  }

  private fun handleSetPlaybackSpeed(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *>
      ?: return result.error("bad_args", "setPlaybackSpeed", null)
    val rate = (args["rate"] as? Number)?.toFloat()
      ?: return result.error("bad_args", "setPlaybackSpeed rate", null)
    withInstance(call, result) { it.setPlaybackSpeed(rate); result.success(null) }
  }

  private inline fun withInstance(
    call: MethodCall,
    result: MethodChannel.Result,
    body: (VideoPlayerInstance) -> Unit,
  ) {
    val args = call.arguments as? Map<*, *>
      ?: return result.error("bad_args", "missing handle", null)
    val handle = (args["handle"] as? Number)?.toInt()
      ?: return result.error("bad_args", "missing handle", null)
    val instance = instances[handle]
      ?: return result.error("disposed", "no player for handle $handle", null)
    body(instance)
  }
}
