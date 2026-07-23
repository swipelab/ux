package io.swipelab.ux.video

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.MatrixTransformation
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.swipelab.ux.NativePlugin
import java.io.File

/// `ux/video/export` (+`/events`) — trim / mute / crop-rotate-flip video
/// export via Media3 Transformer. Trim/mute alone keeps trim
/// optimization on (remux where the source supports it, else the
/// automatic H.264/AAC re-encode). A crop/rotate/flip request adds a
/// `MatrixTransformation` (the caller's source→output affine, applied in
/// NDC) at the caller's output size + bitrate — always a re-encode.
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
    val affine = call.argument<List<Number>>("transform")?.map { it.toDouble() }
    val outWidth = call.argument<Number>("outWidth")?.toInt()
    val outHeight = call.argument<Number>("outHeight")?.toInt()
    val videoBitrate = call.argument<Number>("videoBitrate")?.toInt()
    val overlayPath = call.argument<String>("overlayPath")
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

    val transformed = affine != null && affine.size == 9 &&
      outWidth != null && outHeight != null

    val editedBuilder = EditedMediaItem.Builder(mediaItem).setRemoveAudio(removeAudio)
    if (transformed) {
      // Media3 applies the source rotation before effects, so the frame
      // the transformation sees is already upright — the caller's affine
      // (upright source-px → output-px) maps directly. `configure` sets
      // the output size; `getMatrix` returns the affine expressed in NDC.
      val crop = object : MatrixTransformation {
        private var ndc = Matrix()
        override fun configure(inputWidth: Int, inputHeight: Int): Size {
          ndc = ndcMatrix(affine!!, inputWidth, inputHeight, outWidth!!, outHeight!!)
          return Size(outWidth, outHeight)
        }

        override fun getMatrix(presentationTimeUs: Long): Matrix = ndc
      }
      val effects = mutableListOf<Effect>()
      // Paint strokes composite over the upright source frame BEFORE the
      // crop affine, so they ride the crop. The overlay bitmap shares
      // the frame's dimensions; the default static overlay settings
      // (unscaled, center-anchored) make it an exact cover.
      if (overlayPath != null) {
        val bitmap = BitmapFactory.decodeFile(overlayPath)
        if (bitmap != null) {
          effects.add(
            OverlayEffect(
              listOf<TextureOverlay>(
                BitmapOverlay.createStaticBitmapOverlay(bitmap)
              )
            )
          )
        }
      }
      effects.add(crop)
      editedBuilder.setEffects(Effects(emptyList(), effects))
    }
    val edited = editedBuilder.build()

    val transformerBuilder = Transformer.Builder(context)
    if (transformed) {
      transformerBuilder
        .setVideoMimeType(MimeTypes.VIDEO_H264)
        .setEncoderFactory(
          DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
              VideoEncoderSettings.Builder()
                .setBitrate(videoBitrate ?: 3_000_000)
                .build()
            )
            .build()
        )
    } else {
      transformerBuilder.experimentalSetTrimOptimizationEnabled(true)
    }
    val transformer = transformerBuilder
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

  /// Builds the NDC transform Media3's [MatrixTransformation] applies:
  /// input-NDC → source px → (caller affine) → output px → output-NDC.
  /// [affine] is the row-major 3×3 source-px → output-px matrix
  /// `[a,b,tx, d,e,ty, 0,0,1]`. NDC is `[-1,1]`, y-up; pixel space is
  /// y-down, hence the flipped y rows.
  private fun ndcMatrix(
    affine: List<Double>,
    inW: Int,
    inH: Int,
    outW: Int,
    outH: Int,
  ): Matrix {
    val a = Matrix().apply {
      setValues(
        floatArrayOf(
          affine[0].toFloat(), affine[1].toFloat(), affine[2].toFloat(),
          affine[3].toFloat(), affine[4].toFloat(), affine[5].toFloat(),
          0f, 0f, 1f,
        )
      )
    }
    // input-NDC [-1,1] (y up) → source px (y down)
    val ndcToPxIn = Matrix().apply {
      setValues(
        floatArrayOf(
          inW / 2f, 0f, inW / 2f,
          0f, -inH / 2f, inH / 2f,
          0f, 0f, 1f,
        )
      )
    }
    // output px (y down) → output-NDC [-1,1] (y up)
    val pxToNdcOut = Matrix().apply {
      setValues(
        floatArrayOf(
          2f / outW, 0f, -1f,
          0f, -2f / outH, 1f,
          0f, 0f, 1f,
        )
      )
    }
    return Matrix(ndcToPxIn).apply {
      postConcat(a)
      postConcat(pxToNdcOut)
    }
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
