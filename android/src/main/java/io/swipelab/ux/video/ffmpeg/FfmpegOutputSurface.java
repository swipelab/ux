/*
 * Copyright 2026 swipelab.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 */
package io.swipelab.ux.video.ffmpeg;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.util.Log;
import android.view.Surface;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * EGL/GLES2 helper that converts a decoded YUV420P/YUVJ420P frame into
 * an RGB image written to an Android {@link Surface}. Lives for the
 * duration of one output Surface; the renderer creates a new one when
 * the Surface changes and releases this on shutdown.
 *
 * <p>The fragment shader handles both limited-range BT.709
 * (Android-recorded H.264) and full-range BT.709 (iOS yuvj420p). The
 * decoder flags per-buffer range via
 * {@link VideoDecoderOutputBuffer#decoderPrivate} (0 = limited,
 * 1 = full).
 */
@UnstableApi
final class FfmpegOutputSurface {

  private static final String TAG = "UxFfmpegOutputSurface";

  // Fullscreen quad: (x, y, u, v) per vertex in TRIANGLE_STRIP order
  // (top-left, bottom-left, top-right, bottom-right). UVs encode the
  // rotation that maps a coded-orientation YUV plane onto a
  // display-orientation render target — for each 90° step the UV
  // tuple shifts one vertex around the corner ring. Used by
  // `pickQuad(rotation)` at configure time so the running shader
  // doesn't need a per-frame rotation uniform.
  private static final float[] QUAD_0 = {
      -1f,  1f, 0f, 0f,
      -1f, -1f, 0f, 1f,
       1f,  1f, 1f, 0f,
       1f, -1f, 1f, 1f,
  };
  private static final float[] QUAD_90 = {
      -1f,  1f, 0f, 1f,
      -1f, -1f, 1f, 1f,
       1f,  1f, 0f, 0f,
       1f, -1f, 1f, 0f,
  };
  private static final float[] QUAD_180 = {
      -1f,  1f, 1f, 1f,
      -1f, -1f, 1f, 0f,
       1f,  1f, 0f, 1f,
       1f, -1f, 0f, 0f,
  };
  private static final float[] QUAD_270 = {
      -1f,  1f, 1f, 0f,
      -1f, -1f, 0f, 0f,
       1f,  1f, 1f, 1f,
       1f, -1f, 0f, 1f,
  };

  private static float[] pickQuad(int rotation) {
    switch (((rotation % 360) + 360) % 360) {
      case 90:
        return QUAD_90;
      case 180:
        return QUAD_180;
      case 270:
        return QUAD_270;
      default:
        return QUAD_0;
    }
  }

  private static final String VERTEX_SHADER =
      "attribute vec4 aPos;\n"
      + "attribute vec2 aTex;\n"
      + "varying vec2 vTex;\n"
      + "void main() {\n"
      + "  gl_Position = aPos;\n"
      + "  vTex = aTex;\n"
      + "}\n";

  // BT.709 YUV->RGB. uFullRange selects between full-range (iOS
  // yuvj420p) and limited-range conversion. uSampleScale rescales the
  // horizontal texture coordinate to skip the right-side padding that
  // FFmpeg's SIMD-aligned linesize introduces (yStride >= width).
  private static final String FRAGMENT_SHADER =
      "precision mediump float;\n"
      + "varying vec2 vTex;\n"
      + "uniform sampler2D uY;\n"
      + "uniform sampler2D uU;\n"
      + "uniform sampler2D uV;\n"
      + "uniform float uSampleScale;\n"
      + "uniform float uFullRange;\n"
      + "void main() {\n"
      + "  vec2 c = vec2(vTex.x * uSampleScale, vTex.y);\n"
      + "  float y = texture2D(uY, c).r;\n"
      + "  float u = texture2D(uU, c).r - 0.5;\n"
      + "  float v = texture2D(uV, c).r - 0.5;\n"
      + "  if (uFullRange < 0.5) {\n"
      + "    y = (y - 16.0/255.0) * (255.0/219.0);\n"
      + "    u *= 255.0/224.0;\n"
      + "    v *= 255.0/224.0;\n"
      + "  }\n"
      + "  float r = y + 1.5748 * v;\n"
      + "  float g = y - 0.1873 * u - 0.4681 * v;\n"
      + "  float b = y + 1.8556 * u;\n"
      + "  gl_FragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);\n"
      + "}\n";

  private EGLDisplay eglDisplay = EGL14.EGL_NO_DISPLAY;
  private EGLContext eglContext = EGL14.EGL_NO_CONTEXT;
  private EGLSurface eglSurface = EGL14.EGL_NO_SURFACE;
  private EGLConfig eglConfig;

  private int program;
  private int aPosLoc;
  private int aTexLoc;
  private int uYLoc;
  private int uULoc;
  private int uVLoc;
  private int uSampleScaleLoc;
  private int uFullRangeLoc;

  private final int[] textures = new int[3];
  // Per-plane allocated dimensions; -1 forces a glTexImage2D on the
  // next upload (initial frame or size change). Subsequent frames use
  // glTexSubImage2D which only copies pixels and avoids the driver-
  // side reallocation that glTexImage2D triggers.
  private final int[] allocatedStride = { -1, -1, -1 };
  private final int[] allocatedRows = { -1, -1, -1 };
  private FloatBuffer quadBuffer;

  // Width/height the EGL window surface was created for; taken from
  // the first decoded frame, not eglQuerySurface (which can return
  // stale 1×1 dimensions if the SurfaceTexture's defaultBufferSize
  // wasn't set before window creation).
  private int surfaceWidth;
  private int surfaceHeight;
  // Rotation (clockwise) the configure() call selected the quad UVs
  // for. Used to detect mid-stream rotation changes and rebuild.
  private int configuredRotation;

  /**
   * Binds this helper to the given surface and creates EGL context +
   * GL resources sized for the supplied DISPLAY dimensions (i.e.
   * already swapped for 90°/270° rotated streams). Caller must have
   * already resized the underlying SurfaceTexture (via
   * setDefaultBufferSize) so the EGL window surface picks up matching
   * buffer dimensions on creation.
   *
   * @param rotation 0 / 90 / 180 / 270 — the clockwise rotation that
   *     should be applied to the coded YUV to display correctly.
   *     Selects which set of pre-rotated quad UVs the shader samples
   *     with.
   */
  void configure(Surface surface, int width, int height, int rotation)
      throws FfmpegDecoderException {
    if (eglContext != EGL14.EGL_NO_CONTEXT && eglSurface != EGL14.EGL_NO_SURFACE) {
      return;
    }
    surfaceWidth = width;
    surfaceHeight = height;
    this.configuredRotation = rotation;
    eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
    if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
      throw new FfmpegDecoderException("eglGetDisplay failed");
    }
    int[] version = new int[2];
    if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
      throw new FfmpegDecoderException("eglInitialize failed");
    }

    int[] cfgAttribs = {
        EGL14.EGL_RED_SIZE, 8,
        EGL14.EGL_GREEN_SIZE, 8,
        EGL14.EGL_BLUE_SIZE, 8,
        EGL14.EGL_ALPHA_SIZE, 8,
        EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
        EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
        EGL14.EGL_NONE
    };
    EGLConfig[] cfgs = new EGLConfig[1];
    int[] numCfgs = new int[1];
    if (!EGL14.eglChooseConfig(eglDisplay, cfgAttribs, 0, cfgs, 0, 1, numCfgs, 0)
        || numCfgs[0] < 1) {
      throw new FfmpegDecoderException("eglChooseConfig failed");
    }
    eglConfig = cfgs[0];

    int[] ctxAttribs = { EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE };
    eglContext =
        EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0);
    if (eglContext == EGL14.EGL_NO_CONTEXT) {
      throw new FfmpegDecoderException("eglCreateContext failed");
    }

    int[] surfAttribs = { EGL14.EGL_NONE };
    eglSurface =
        EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, surfAttribs, 0);
    if (eglSurface == EGL14.EGL_NO_SURFACE) {
      throw new FfmpegDecoderException("eglCreateWindowSurface failed");
    }

    if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
      throw new FfmpegDecoderException("eglMakeCurrent failed");
    }

    initGl();
  }

  private void initGl() throws FfmpegDecoderException {
    int vs = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER);
    int fs = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER);
    program = GLES20.glCreateProgram();
    GLES20.glAttachShader(program, vs);
    GLES20.glAttachShader(program, fs);
    GLES20.glLinkProgram(program);
    int[] linked = new int[1];
    GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0);
    if (linked[0] == 0) {
      String log = GLES20.glGetProgramInfoLog(program);
      throw new FfmpegDecoderException("Program link failed: " + log);
    }
    GLES20.glDeleteShader(vs);
    GLES20.glDeleteShader(fs);

    aPosLoc = GLES20.glGetAttribLocation(program, "aPos");
    aTexLoc = GLES20.glGetAttribLocation(program, "aTex");
    uYLoc = GLES20.glGetUniformLocation(program, "uY");
    uULoc = GLES20.glGetUniformLocation(program, "uU");
    uVLoc = GLES20.glGetUniformLocation(program, "uV");
    uSampleScaleLoc = GLES20.glGetUniformLocation(program, "uSampleScale");
    uFullRangeLoc = GLES20.glGetUniformLocation(program, "uFullRange");

    GLES20.glGenTextures(3, textures, 0);
    for (int i = 0; i < 3; i++) {
      int t = textures[i];
      // Y plane (i=0) is 1:1 sized to the EGL surface, so GL_NEAREST
      // samples the exact texel value at each pixel center and
      // preserves luma detail. Chroma planes (i=1,2) are 4:2:0
      // subsampled — bilinear filtering reconstructs the smooth
      // colour transitions the encoder expected.
      int filter = i == 0 ? GLES20.GL_NEAREST : GLES20.GL_LINEAR;
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, t);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, filter);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, filter);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S,
          GLES20.GL_CLAMP_TO_EDGE);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T,
          GLES20.GL_CLAMP_TO_EDGE);
    }

    float[] quad = pickQuad(configuredRotation);
    quadBuffer =
        ByteBuffer.allocateDirect(quad.length * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer();
    quadBuffer.put(quad).position(0);

    GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1);
  }

  private static int compileShader(int type, String src) throws FfmpegDecoderException {
    int s = GLES20.glCreateShader(type);
    GLES20.glShaderSource(s, src);
    GLES20.glCompileShader(s);
    int[] ok = new int[1];
    GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0);
    if (ok[0] == 0) {
      String log = GLES20.glGetShaderInfoLog(s);
      GLES20.glDeleteShader(s);
      throw new FfmpegDecoderException(
          (type == GLES20.GL_VERTEX_SHADER ? "Vertex" : "Fragment")
              + " shader compile failed: "
              + log);
    }
    return s;
  }

  /**
   * Uploads the YUV planes from {@code buffer} into GL textures and
   * draws the conversion shader to the EGL window surface. Caller is
   * responsible for calling {@code buffer.release()} afterwards.
   *
   * @param rotation rotation degrees from the source format. Must
   *     match the value passed to {@link #configure} (used here only
   *     to recover the CODED Y-plane dimensions — needed for the
   *     stride-vs-width sample-scale calculation — from the buffer's
   *     DISPLAY-orientation width/height).
   */
  void render(VideoDecoderOutputBuffer buffer, int rotation) throws FfmpegDecoderException {
    if (eglContext == EGL14.EGL_NO_CONTEXT || eglSurface == EGL14.EGL_NO_SURFACE) {
      throw new FfmpegDecoderException("render called before configure");
    }
    if (buffer.yuvPlanes == null || buffer.yuvStrides == null) {
      throw new FfmpegDecoderException("output buffer has no YUV data");
    }

    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);

    int yStride = buffer.yuvStrides[0];
    int uvStride = buffer.yuvStrides[1];
    // For 90°/270° streams the renderer swapped buffer.width/height
    // to display orientation so ExoPlayer's size notification was
    // correct, but the YUV planes are still stored in coded
    // orientation — undo the swap here so sampleScale = codedWidth /
    // yStride lands on the correct value.
    boolean rotated = rotation == 90 || rotation == 270;
    int codedWidth = rotated ? buffer.height : buffer.width;
    int codedHeight = rotated ? buffer.width : buffer.height;
    int uvHeight = (codedHeight + 1) / 2;

    GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight);
    GLES20.glClearColor(0f, 0f, 0f, 1f);
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);

    GLES20.glUseProgram(program);

    uploadPlane(0, textures[0], buffer.yuvPlanes[0], yStride, codedHeight);
    uploadPlane(1, textures[1], buffer.yuvPlanes[1], uvStride, uvHeight);
    uploadPlane(2, textures[2], buffer.yuvPlanes[2], uvStride, uvHeight);

    GLES20.glUniform1i(uYLoc, 0);
    GLES20.glUniform1i(uULoc, 1);
    GLES20.glUniform1i(uVLoc, 2);
    GLES20.glUniform1f(uSampleScaleLoc, yStride > 0 ? (float) codedWidth / yStride : 1f);
    GLES20.glUniform1f(uFullRangeLoc, buffer.decoderPrivate == 1L ? 1f : 0f);

    quadBuffer.position(0);
    GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 16, quadBuffer);
    quadBuffer.position(2);
    GLES20.glVertexAttribPointer(aTexLoc, 2, GLES20.GL_FLOAT, false, 16, quadBuffer);
    GLES20.glEnableVertexAttribArray(aPosLoc);
    GLES20.glEnableVertexAttribArray(aTexLoc);

    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);

    GLES20.glDisableVertexAttribArray(aPosLoc);
    GLES20.glDisableVertexAttribArray(aTexLoc);

    if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
      Log.w(TAG, "eglSwapBuffers failed; client may have detached the surface");
    }
  }

  private void uploadPlane(
      int unit, int texture, ByteBuffer src, int stride, int rows) {
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
    src.position(0);
    if (allocatedStride[unit] == stride && allocatedRows[unit] == rows) {
      GLES20.glTexSubImage2D(
          GLES20.GL_TEXTURE_2D,
          0,
          0, 0,
          stride, rows,
          GLES20.GL_LUMINANCE,
          GLES20.GL_UNSIGNED_BYTE,
          src);
    } else {
      GLES20.glTexImage2D(
          GLES20.GL_TEXTURE_2D,
          0,
          GLES20.GL_LUMINANCE,
          stride,
          rows,
          0,
          GLES20.GL_LUMINANCE,
          GLES20.GL_UNSIGNED_BYTE,
          src);
      allocatedStride[unit] = stride;
      allocatedRows[unit] = rows;
    }
  }

  void release() {
    if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
      EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
          EGL14.EGL_NO_CONTEXT);
      if (textures[0] != 0) {
        GLES20.glDeleteTextures(3, textures, 0);
        textures[0] = textures[1] = textures[2] = 0;
      }
      if (program != 0) {
        GLES20.glDeleteProgram(program);
        program = 0;
      }
      if (eglSurface != EGL14.EGL_NO_SURFACE) {
        EGL14.eglDestroySurface(eglDisplay, eglSurface);
        eglSurface = EGL14.EGL_NO_SURFACE;
      }
      if (eglContext != EGL14.EGL_NO_CONTEXT) {
        EGL14.eglDestroyContext(eglDisplay, eglContext);
        eglContext = EGL14.EGL_NO_CONTEXT;
      }
      EGL14.eglReleaseThread();
      EGL14.eglTerminate(eglDisplay);
      eglDisplay = EGL14.EGL_NO_DISPLAY;
    }
    quadBuffer = null;
  }
}
