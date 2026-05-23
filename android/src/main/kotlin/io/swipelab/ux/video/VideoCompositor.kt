package io.swipelab.ux.video

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/// GLES-based blit between an internal `SurfaceTexture` (codec input)
/// and a Flutter `SurfaceTextureEntry`-backed `Surface` (output).
///
/// Why this exists: on Huawei EMUI 10 the software AVC decoder
/// (`c2.android.avc.decoder`) writes YUV frames into a stride-padded
/// buffer and sets a SurfaceTexture transform matrix that doesn't
/// fully describe the crop — Flutter's `Texture` widget then samples
/// the padding bytes and shows a green strip on the right edge.
/// Platform-view paths sidestep this but lose smooth gallery
/// animations; Media3's `DefaultVideoFrameProcessor` won't render
/// into a SurfaceTexture-backed Surface (it drops every frame with
/// "FinalShaderWrapper: Output surface and size not set"). So we run
/// our own one-shader blit downstream of the codec.
///
/// Lifecycle:
///   1. [start] — EGL display + context + a tiny pbuffer surface so
///      the context can be current before any output exists. Creates
///      the input `SurfaceTexture` + Surface and hands the Surface to
///      the caller via [onInputSurfaceReady].
///   2. [setDisplaySize] — first call (typically from
///      `Player.Listener.onVideoSizeChanged`) sizes the Flutter
///      output `SurfaceTexture` to match the codec exactly and
///      creates the EGL window surface. Until then `drawFrame`
///      consumes input frames (so the codec doesn't stall on a full
///      queue) but does not paint — there is no output to paint to
///      and no dimensions to invent.
///   3. [dispose] — tears down the render thread, GL, both EGL
///      surfaces, and the context.
@UnstableApi
internal class VideoCompositor(
  private val outputSurface: Surface,
  /// Called once the input `SurfaceTexture` is ready and wrapped in a
  /// Surface. The caller (typically [VideoPlayerInstance]) hands this
  /// Surface to ExoPlayer via `setVideoSurface`. Fires on the render
  /// thread.
  private val onInputSurfaceReady: (Surface) -> Unit,
  /// Fires exactly once, on the render thread, after the first
  /// `eglSwapBuffers` lands a real frame on [outputSurface]. The
  /// player instance uses this to gate `initialize()` resolution so
  /// the gallery's thumb→texture swap happens against a populated
  /// texture, not an empty one (avoids the black flash on hero
  /// landing).
  private val onFirstFrame: (() -> Unit)? = null,
  /// Called when the codec's display dimensions land, with the same
  /// width / height [setDisplaySize] was called with. Lets the owning
  /// instance resize the Flutter `SurfaceTexture`'s `defaultBufferSize`
  /// in sync with the EGL window surface. Fires on the render thread.
  private val onOutputSized: ((Int, Int) -> Unit)? = null,
) {
  private val thread = HandlerThread("ux.video.compositor", Thread.NORM_PRIORITY)
  private lateinit var handler: Handler

  // GL state lives on the render thread.
  private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
  private var eglConfig: EGLConfig? = null
  private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
  private var eglPbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE
  private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
  private var inputTextureId: Int = 0
  private var inputSurfaceTexture: SurfaceTexture? = null
  private var inputSurface: Surface? = null

  private var program: Int = 0
  private var aPositionLoc: Int = -1
  private var aTexCoordLoc: Int = -1
  private var uStMatrixLoc: Int = -1
  private var uCropMatrixLoc: Int = -1

  private val stMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
  private val cropMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

  /// Codec-reported display dimensions. Zero until [setDisplaySize]
  /// has been called by the player listener.
  private var displayWidth: Int = 0
  private var displayHeight: Int = 0

  private val quadVertices: FloatBuffer = ByteBuffer
    .allocateDirect(QUAD_COORDS.size * 4)
    .order(ByteOrder.nativeOrder())
    .asFloatBuffer()
    .apply { put(QUAD_COORDS).position(0) }

  private val quadTexCoords: FloatBuffer = ByteBuffer
    .allocateDirect(QUAD_TEXCOORDS.size * 4)
    .order(ByteOrder.nativeOrder())
    .asFloatBuffer()
    .apply { put(QUAD_TEXCOORDS).position(0) }

  private var disposed = false
  private var firstFrameDelivered = false

  fun start() {
    thread.start()
    handler = Handler(thread.looper)
    handler.post {
      try {
        setupEgl()
        Log.i(TAG, "egl ready ctx=$eglContext pbuf=$eglPbufferSurface")
        setupProgram()
        Log.i(TAG, "program ready id=$program")
        setupInputSurfaceTexture()
        Log.i(TAG, "input ready tex=$inputTextureId surface=$inputSurface")
        onInputSurfaceReady(inputSurface!!)
      } catch (t: Throwable) {
        Log.e(TAG, "compositor.start failed", t)
        teardown()
      }
    }
  }

  fun setDisplaySize(width: Int, height: Int) {
    if (disposed) return
    if (width <= 0 || height <= 0) return
    handler.post {
      val changed = width != displayWidth || height != displayHeight
      if (!changed) return@post
      displayWidth = width
      displayHeight = height
      onOutputSized?.invoke(width, height)
      Log.i(TAG, "setDisplaySize ${width}x$height window=$eglWindowSurface")
      if (eglWindowSurface == EGL14.EGL_NO_SURFACE) {
        try {
          createWindowSurface()
          Log.i(TAG, "window surface created $eglWindowSurface")
          // ExoPlayer in default `playWhenReady = false` decodes
          // exactly one preview frame and then pauses waiting for
          // `play()` — that frame is already sitting in the input
          // SurfaceTexture (we called `updateTexImage` on the
          // pre-window draw attempt). Without a follow-up draw the
          // first-frame signal never fires, `initialize()` never
          // resolves on the Dart side, the gallery never transitions
          // to ready and autoplay never triggers. Paint that cached
          // frame to the Flutter output now.
          drawFrame()
        } catch (t: Throwable) {
          Log.e(TAG, "createWindowSurface failed", t)
        }
      }
    }
  }

  fun dispose() {
    if (disposed) return
    disposed = true
    handler.post {
      teardown()
      thread.quitSafely()
    }
  }

  // ---- render thread ---------------------------------------------------

  private fun setupEgl() {
    eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    if (eglDisplay == EGL14.EGL_NO_DISPLAY) error("eglGetDisplay failed")
    val version = IntArray(2)
    if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
      error("eglInitialize failed")
    }
    val configAttribs = intArrayOf(
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      // Surface type covers both window (output) and pbuffer
      // (bootstrap) — same config serves both.
      EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val numConfigs = IntArray(1)
    if (!EGL14.eglChooseConfig(
        eglDisplay, configAttribs, 0, configs, 0, configs.size, numConfigs, 0,
      ) || numConfigs[0] == 0
    ) {
      error("eglChooseConfig failed")
    }
    eglConfig = configs[0]
    val contextAttribs = intArrayOf(
      EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
      EGL14.EGL_NONE,
    )
    eglContext = EGL14.eglCreateContext(
      eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0,
    )
    if (eglContext == EGL14.EGL_NO_CONTEXT) error("eglCreateContext failed")
    val pbufferAttribs = intArrayOf(
      EGL14.EGL_WIDTH, 1,
      EGL14.EGL_HEIGHT, 1,
      EGL14.EGL_NONE,
    )
    eglPbufferSurface = EGL14.eglCreatePbufferSurface(
      eglDisplay, eglConfig, pbufferAttribs, 0,
    )
    if (eglPbufferSurface == EGL14.EGL_NO_SURFACE) error("eglCreatePbufferSurface failed")
    if (!EGL14.eglMakeCurrent(
        eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext,
      )
    ) {
      error("eglMakeCurrent(pbuffer) failed")
    }
  }

  private fun createWindowSurface() {
    val config = eglConfig ?: error("createWindowSurface before setupEgl")
    val attribs = intArrayOf(EGL14.EGL_NONE)
    val surface = EGL14.eglCreateWindowSurface(
      eglDisplay, config, outputSurface, attribs, 0,
    )
    if (surface == EGL14.EGL_NO_SURFACE) error("eglCreateWindowSurface failed")
    eglWindowSurface = surface
    if (!EGL14.eglMakeCurrent(eglDisplay, surface, surface, eglContext)) {
      error("eglMakeCurrent(window) failed")
    }
  }

  private fun setupProgram() {
    val vsh = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
    val fsh = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
    program = GLES20.glCreateProgram()
    GLES20.glAttachShader(program, vsh)
    GLES20.glAttachShader(program, fsh)
    GLES20.glLinkProgram(program)
    val linked = IntArray(1)
    GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
    if (linked[0] == 0) {
      val info = GLES20.glGetProgramInfoLog(program)
      GLES20.glDeleteProgram(program)
      program = 0
      error("Program link failed: $info")
    }
    GLES20.glDeleteShader(vsh)
    GLES20.glDeleteShader(fsh)
    aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
    aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTexCoord")
    uStMatrixLoc = GLES20.glGetUniformLocation(program, "uStMatrix")
    uCropMatrixLoc = GLES20.glGetUniformLocation(program, "uCropMatrix")
  }

  private fun setupInputSurfaceTexture() {
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    inputTextureId = ids[0]
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputTextureId)
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
      GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
    )
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
      GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
    )
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
      GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
    )
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
      GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
    )
    val st = SurfaceTexture(inputTextureId)
    st.setOnFrameAvailableListener({ _ ->
      if (disposed) return@setOnFrameAvailableListener
      handler.post { drawFrame() }
    }, handler)
    inputSurfaceTexture = st
    inputSurface = Surface(st)
  }

  private fun drawFrame() {
    if (disposed) return
    val st = inputSurfaceTexture ?: return
    try {
      // Always consume the input frame so the codec's surface queue
      // doesn't fill up and stall, even before the EGL window
      // surface exists.
      st.updateTexImage()
      st.getTransformMatrix(stMatrix)
    } catch (t: Throwable) {
      Log.e(TAG, "updateTexImage failed", t)
      return
    }
    if (eglWindowSurface == EGL14.EGL_NO_SURFACE) {
      Log.i(TAG, "drawFrame skipped: no window surface yet")
      return
    }
    if (displayWidth <= 0 || displayHeight <= 0) return

    GLES20.glViewport(0, 0, displayWidth, displayHeight)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    GLES20.glUseProgram(program)

    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputTextureId)

    GLES20.glUniformMatrix4fv(uStMatrixLoc, 1, false, stMatrix, 0)
    GLES20.glUniformMatrix4fv(uCropMatrixLoc, 1, false, cropMatrix, 0)

    quadVertices.position(0)
    GLES20.glEnableVertexAttribArray(aPositionLoc)
    GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
    quadTexCoords.position(0)
    GLES20.glEnableVertexAttribArray(aTexCoordLoc)
    GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

    GLES20.glDisableVertexAttribArray(aPositionLoc)
    GLES20.glDisableVertexAttribArray(aTexCoordLoc)

    EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)

    if (!firstFrameDelivered) {
      firstFrameDelivered = true
      Log.i(TAG, "first frame delivered to Flutter texture")
      onFirstFrame?.invoke()
    }
  }

  private fun teardown() {
    inputSurface?.release()
    inputSurface = null
    inputSurfaceTexture?.release()
    inputSurfaceTexture = null
    if (inputTextureId != 0) {
      GLES20.glDeleteTextures(1, intArrayOf(inputTextureId), 0)
      inputTextureId = 0
    }
    if (program != 0) {
      GLES20.glDeleteProgram(program)
      program = 0
    }
    if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
      EGL14.eglMakeCurrent(
        eglDisplay,
        EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_CONTEXT,
      )
      if (eglWindowSurface != EGL14.EGL_NO_SURFACE) {
        EGL14.eglDestroySurface(eglDisplay, eglWindowSurface)
        eglWindowSurface = EGL14.EGL_NO_SURFACE
      }
      if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
        EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface)
        eglPbufferSurface = EGL14.EGL_NO_SURFACE
      }
      if (eglContext != EGL14.EGL_NO_CONTEXT) {
        EGL14.eglDestroyContext(eglDisplay, eglContext)
        eglContext = EGL14.EGL_NO_CONTEXT
      }
      EGL14.eglTerminate(eglDisplay)
      eglDisplay = EGL14.EGL_NO_DISPLAY
    }
  }

  private fun compileShader(type: Int, source: String): Int {
    val shader = GLES20.glCreateShader(type)
    GLES20.glShaderSource(shader, source)
    GLES20.glCompileShader(shader)
    val status = IntArray(1)
    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
    if (status[0] == 0) {
      val info = GLES20.glGetShaderInfoLog(shader)
      GLES20.glDeleteShader(shader)
      error("Shader compile failed: $info")
    }
    return shader
  }

  companion object {
    private const val TAG = "UxVideoCompositor"

    /// Full-screen triangle strip in clip space (4 verts, 2 triangles).
    private val QUAD_COORDS = floatArrayOf(
      -1f, -1f,
      1f, -1f,
      -1f, 1f,
      1f, 1f,
    )

    private val QUAD_TEXCOORDS = floatArrayOf(
      0f, 0f,
      1f, 0f,
      0f, 1f,
      1f, 1f,
    )

    private val VERTEX_SHADER = """
      attribute vec4 aPosition;
      attribute vec2 aTexCoord;
      uniform mat4 uStMatrix;
      uniform mat4 uCropMatrix;
      varying vec2 vTexCoord;
      void main() {
        gl_Position = aPosition;
        vec4 tc = uStMatrix * uCropMatrix * vec4(aTexCoord, 0.0, 1.0);
        vTexCoord = tc.xy;
      }
    """.trimIndent()

    private val FRAGMENT_SHADER = """
      #extension GL_OES_EGL_image_external : require
      precision mediump float;
      uniform samplerExternalOES uTexture;
      varying vec2 vTexCoord;
      void main() {
        gl_FragColor = texture2D(uTexture, vTexCoord);
      }
    """.trimIndent()
  }
}
