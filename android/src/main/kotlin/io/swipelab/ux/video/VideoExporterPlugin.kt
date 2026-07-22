package io.swipelab.ux.video

import android.content.Context
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.swipelab.ux.NativePlugin
import java.io.File

/// `ux/video/export` (+`/events`) — trim / mute video export via
/// Media3 Transformer. Trim optimization keeps supported sources in
/// remux territory; unsupported codec/container combinations fall
/// back to Transformer's H.264/AAC re-encode automatically.
@UnstableApi
class VideoExporterPlugin :
  NativePlugin,
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler {

  private val main = Handler(Looper.getMainLooper())

  private var context: Context? = null
  private var methodChannel: MethodChannel? = null
  private var eventChannel: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null

  private val sessions = mutableMapOf<Int, ActiveExport>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    methodChannel = MethodChannel(binding.binaryMessenger, "ux/video/export")
    methodChannel?.setMethodCallHandler(this)
    eventChannel = EventChannel(binding.binaryMessenger, "ux/video/export/events")
    eventChannel?.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    sessions.values.forEach { it.stop() }
    sessions.clear()
    methodChannel?.setMethodCallHandler(null)
    eventChannel?.setStreamHandler(null)
    methodChannel = null
    eventChannel = null
    context = null
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  private fun emit(payload: Map<String, Any?>) {
    main.post { eventSink?.success(payload) }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> start(call, result)
      "cancel" -> cancel(call, result)
      else -> result.notImplemented()
    }
  }

  private fun start(call: MethodCall, result: MethodChannel.Result) {
    val context = context
    val sessionId = call.argument<Number>("sessionId")?.toInt()
    val path = call.argument<String>("path")
    val outPath = call.argument<String>("outPath")
    if (context == null || sessionId == null || path == null || outPath == null) {
      result.error("bad_args", "sessionId, path, outPath required", null)
      return
    }
    val trimStartMs = call.argument<Number>("trimStartMs")?.toLong()
    val trimEndMs = call.argument<Number>("trimEndMs")?.toLong()
    val removeAudio = call.argument<Boolean>("removeAudio") ?: false
    result.success(null)

    File(outPath).delete()

    val clipping = MediaItem.ClippingConfiguration.Builder().apply {
      if (trimStartMs != null) setStartPositionMs(trimStartMs)
      if (trimEndMs != null) setEndPositionMs(trimEndMs)
    }.build()
    val mediaItem = MediaItem.Builder()
      .setUri(android.net.Uri.fromFile(File(path)))
      .setClippingConfiguration(clipping)
      .build()
    val edited = EditedMediaItem.Builder(mediaItem)
      .setRemoveAudio(removeAudio)
      .build()

    val transformer = Transformer.Builder(context)
      .experimentalSetTrimOptimizationEnabled(true)
      .addListener(object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          sessions.remove(sessionId)?.stopProgress()
          val (w, h, durationMs) = probe(outPath)
          emit(
            mapOf(
              "sessionId" to sessionId, "type" to "done",
              "path" to outPath,
              "width" to w, "height" to h,
              "durationMs" to durationMs,
            )
          )
        }

        override fun onError(
          composition: Composition,
          exportResult: ExportResult,
          exportException: ExportException,
        ) {
          sessions.remove(sessionId)?.stopProgress()
          File(outPath).delete()
          emit(
            mapOf(
              "sessionId" to sessionId, "type" to "error",
              "code" to "export_failed",
              "message" to (exportException.message ?: "unknown"),
            )
          )
        }
      })
      .build()

    val active = ActiveExport(transformer, outPath)
    sessions[sessionId] = active
    transformer.start(edited, outPath)

    val holder = ProgressHolder()
    val poll = object : Runnable {
      override fun run() {
        val session = sessions[sessionId] ?: return
        val state = session.transformer.getProgress(holder)
        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
          emit(
            mapOf(
              "sessionId" to sessionId, "type" to "progress",
              "value" to holder.progress / 100.0,
            )
          )
        }
        main.postDelayed(this, 100)
      }
    }
    active.progressPoll = poll
    main.postDelayed(poll, 100)
  }

  private fun cancel(call: MethodCall, result: MethodChannel.Result) {
    val sessionId = call.argument<Number>("sessionId")?.toInt()
    if (sessionId == null) {
      result.error("bad_args", "sessionId required", null)
      return
    }
    sessions.remove(sessionId)?.let { session ->
      session.stop()
      File(session.outPath).delete()
      emit(
        mapOf(
          "sessionId" to sessionId, "type" to "error",
          "code" to "cancelled", "message" to "export cancelled",
        )
      )
    }
    result.success(null)
  }

  private fun probe(path: String): Triple<Int, Int, Long> {
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(path)
      fun meta(key: Int) =
        retriever.extractMetadata(key)?.toLongOrNull() ?: 0L
      val rotation = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
      var w = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH).toInt()
      var h = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT).toInt()
      if (rotation == 90L || rotation == 270L) {
        val t = w; w = h; h = t
      }
      Triple(w, h, meta(MediaMetadataRetriever.METADATA_KEY_DURATION))
    } catch (_: Exception) {
      Triple(0, 0, 0L)
    } finally {
      retriever.release()
    }
  }

  private inner class ActiveExport(
    val transformer: Transformer,
    val outPath: String,
  ) {
    var progressPoll: Runnable? = null

    fun stopProgress() {
      progressPoll?.let { main.removeCallbacks(it) }
      progressPoll = null
    }

    fun stop() {
      stopProgress()
      transformer.cancel()
    }
  }
}
