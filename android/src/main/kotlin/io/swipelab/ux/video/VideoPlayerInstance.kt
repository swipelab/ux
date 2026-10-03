package io.swipelab.ux.video

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.view.TextureRegistry

/// How [VideoPlayerInstance.prepare] ends.
internal sealed interface PrepareResult {
  data class Ready(val size: VideoSize, val durationMs: Long) : PrepareResult
  data class Failed(val error: Throwable) : PrepareResult
  data object Disposed : PrepareResult
}

/// One per Dart-side `XVideoPlayerController`. Owns:
///   - the [ExoPlayer] built with our renderer-factory (decoder
///     fallback + `OMX.hisi.*` deprioritise)
///   - a [VideoCompositor] that runs a one-shader GLES blit between
///     the codec's output surface and the Flutter
///     [TextureRegistry.SurfaceTextureEntry] the Dart-side
///     `Texture(textureId:)` widget samples
///
/// Methods run on the main thread.
@UnstableApi
internal class VideoPlayerInstance(
  val handle: Int,
  private val context: Context,
  private val textureEntry: TextureRegistry.SurfaceTextureEntry,
) {
  /// Pushed to Dart as `{event, handle, …}` payloads. Set by the plugin.
  var onEvent: ((Map<String, Any?>) -> Unit)? = null

  val textureId: Long get() = textureEntry.id()

  private val mainHandler = Handler(Looper.getMainLooper())

  /// Wrapped around the Flutter `SurfaceTextureEntry`'s `SurfaceTexture`.
  /// We deliberately do NOT call `setDefaultBufferSize` here — that
  /// would lock the Flutter texture to an arbitrary aspect ratio
  /// before the codec reports the real one, causing a visible flicker
  /// at the moment the gallery flips from thumbnail to live texture.
  /// The compositor delays creating its EGL window surface (and thus
  /// allocating any backing buffer) until the codec's dimensions
  /// arrive via [onOutputSized] below — at which point we size the
  /// SurfaceTexture in the same render-thread tick.
  private val outputSurface: Surface = Surface(textureEntry.surfaceTexture())
  private val compositor = VideoCompositor(
    outputSurface = outputSurface,
    onInputSurfaceReady = { inputSurface ->
      mainHandler.post {
        if (disposed) {
          Log.i(TAG, "h$handle setVideoSurface skipped (disposed)")
          return@post
        }
        Log.i(TAG, "h$handle setVideoSurface=$inputSurface")
        player.setVideoSurface(inputSurface)
      }
    },
    onFirstFrame = {
      // Fires on the compositor's render thread.
      mainHandler.post {
        if (disposed) return@post
        Log.i(TAG, "h$handle firstFrameRendered")
        firstFrameRendered = true
        maybeResolvePrepare()
      }
    },
    onOutputSized = { width, height ->
      // Render thread — safe to touch the SurfaceTexture here.
      // Setting `defaultBufferSize` immediately before the
      // compositor calls `eglCreateWindowSurface` keeps the EGL
      // surface's natural dimensions matched to the codec.
      textureEntry.surfaceTexture().setDefaultBufferSize(width, height)
    },
  )

  private val player: ExoPlayer = ExoPlayer.Builder(
    context,
    // FFmpeg renderer calls this on its own thread before it builds
    // an EGL window surface against the codec-input Surface. Sizes
    // the compositor's INPUT SurfaceTexture so the EGL surface
    // inherits matching buffer dimensions on creation.
    Renderers.build(context) { w, h -> compositor.setInputSurfaceSize(w, h) },
  ).build()

  private var disposed = false
  private var firstFrameRendered = false
  private var stateReady = false
  private var pendingPrepare: ((PrepareResult) -> Unit)? = null
  private var lastReportedWidth: Int = -1
  private var lastReportedHeight: Int = -1
  private var lastReportedBufferedMs: Long = -1L
  private var lastIsPlaying: Boolean = false
  private var lastIsBuffering: Boolean = false

  private val tickRunnable = object : Runnable {
    override fun run() {
      if (disposed) return
      emitPositionAndBuffer()
      mainHandler.postDelayed(this, POSITION_TICK_MS)
    }
  }

  private val listener = object : Player.Listener {
    override fun onPlaybackStateChanged(state: Int) {
      val buffering = state == Player.STATE_BUFFERING
      if (buffering != lastIsBuffering) {
        lastIsBuffering = buffering
        emitStateChange(isBuffering = buffering)
      }
      if (state == Player.STATE_ENDED &&
        player.repeatMode != Player.REPEAT_MODE_ONE &&
        player.repeatMode != Player.REPEAT_MODE_ALL
      ) {
        emit(mapOf("event" to "completed"))
      }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
      if (isPlaying != lastIsPlaying) {
        lastIsPlaying = isPlaying
        emitStateChange(isPlaying = isPlaying)
      }
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
      if (videoSize.width != lastReportedWidth || videoSize.height != lastReportedHeight) {
        lastReportedWidth = videoSize.width
        lastReportedHeight = videoSize.height
        Log.i(TAG, "h$handle onVideoSizeChanged ${videoSize.width}x${videoSize.height}")
        if (videoSize.width > 0 && videoSize.height > 0) {
          // Compositor sizes the Flutter SurfaceTexture and creates
          // its EGL window surface in one render-thread step (see
          // [VideoCompositor.setDisplaySize] + the `onOutputSized`
          // wiring above), so the Flutter `Texture` widget's first
          // visible frame already has correct natural dimensions.
          compositor.setDisplaySize(videoSize.width, videoSize.height)
        }
        emit(
          mapOf(
            "event" to "sizeChanged",
            "size" to mapOf(
              "width" to videoSize.width.toDouble(),
              "height" to videoSize.height.toDouble(),
            ),
          ),
        )
      }
    }

    override fun onPlayerError(error: PlaybackException) {
      emit(
        mapOf(
          "event" to "error",
          "code" to error.errorCodeName,
          "description" to (error.message ?: error.errorCodeName),
        ),
      )
    }
  }

  init {
    player.addListener(listener)
    // Compositor allocates EGL + GLES on its own thread, then hands
    // back the input Surface for the codec via onInputSurfaceReady.
    compositor.start()
  }

  fun setSource(uri: Uri) {
    check(!disposed)
    player.setMediaItem(MediaItem.fromUri(uri))
  }

  fun prepare(onReady: (PrepareResult) -> Unit) {
    check(!disposed)
    pendingPrepare = onReady
    val prepListener = object : Player.Listener {
      override fun onPlaybackStateChanged(state: Int) {
        if (disposed) return
        if (state == Player.STATE_READY) {
          player.removeListener(this)
          stateReady = true
          maybeResolvePrepare()
        }
      }

      override fun onPlayerError(error: PlaybackException) {
        player.removeListener(this)
        val cb = pendingPrepare ?: return
        pendingPrepare = null
        cb(PrepareResult.Failed(error))
      }
    }
    player.addListener(prepListener)
    player.prepare()
  }

  /// Resolves the pending prepare future once *both* the ExoPlayer
  /// has reached `STATE_READY` AND the compositor has landed the
  /// first blitted frame on the Flutter output surface. The gallery
  /// uses this future to swap from the thumbnail to the live
  /// `Texture`; resolving early causes a black-flash on the hero
  /// landing.
  private fun maybeResolvePrepare() {
    val cb = pendingPrepare ?: return
    if (!stateReady || !firstFrameRendered) return
    pendingPrepare = null
    cb(PrepareResult.Ready(player.videoSize, player.duration.coerceAtLeast(0L)))
    mainHandler.post(tickRunnable)
  }

  fun play() {
    if (disposed) return
    player.play()
  }

  fun pause() {
    if (disposed) return
    player.pause()
  }

  fun seekTo(positionMs: Long) {
    if (disposed) return
    player.seekTo(positionMs)
    emitPositionAndBuffer(forcePosition = positionMs)
  }

  fun setLooping(loop: Boolean) {
    if (disposed) return
    player.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
  }

  fun setVolume(volume: Float) {
    if (disposed) return
    player.volume = volume.coerceIn(0f, 1f)
  }

  fun setPlaybackSpeed(rate: Float) {
    if (disposed) return
    player.setPlaybackSpeed(rate.coerceIn(0.25f, 4f))
  }

  fun dispose() {
    if (disposed) return
    disposed = true
    mainHandler.removeCallbacks(tickRunnable)
    player.removeListener(listener)
    player.release()
    // Compositor disposal posts to its own thread; safe to call after
    // player.release because the compositor stops drawing once the
    // input SurfaceTexture stops receiving frames.
    compositor.dispose()
    outputSurface.release()
    textureEntry.release()
    onEvent = null
    val cb = pendingPrepare ?: return
    pendingPrepare = null
    cb(PrepareResult.Disposed)
  }

  private fun emitPositionAndBuffer(forcePosition: Long? = null) {
    if (disposed) return
    val position = forcePosition ?: player.currentPosition.coerceAtLeast(0L)
    val bufferedMs = player.bufferedPosition.coerceAtLeast(0L)
    if (bufferedMs == lastReportedBufferedMs && forcePosition == null && !lastIsPlaying) {
      return
    }
    lastReportedBufferedMs = bufferedMs
    emit(
      mapOf(
        "event" to "stateChanged",
        "positionMs" to position,
        "buffered" to listOf(
          mapOf(
            "startMs" to 0L,
            "endMs" to bufferedMs,
          ),
        ),
      ),
    )
  }

  private fun emitStateChange(isPlaying: Boolean? = null, isBuffering: Boolean? = null) {
    val payload = HashMap<String, Any?>()
    payload["event"] = "stateChanged"
    payload["positionMs"] = player.currentPosition.coerceAtLeast(0L)
    if (isPlaying != null) payload["isPlaying"] = isPlaying
    if (isBuffering != null) payload["isBuffering"] = isBuffering
    emit(payload)
  }

  private fun emit(extras: Map<String, Any?>) {
    val payload = HashMap<String, Any?>(extras.size + 1)
    payload["handle"] = handle
    payload.putAll(extras)
    onEvent?.invoke(payload)
  }

  companion object {
    private const val TAG = "UxVideoPlayer"
    private const val POSITION_TICK_MS = 100L
  }
}
