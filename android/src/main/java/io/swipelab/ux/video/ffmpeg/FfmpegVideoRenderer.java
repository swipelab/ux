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

import static androidx.media3.exoplayer.DecoderReuseEvaluation.DISCARD_REASON_MIME_TYPE_CHANGED;
import static androidx.media3.exoplayer.DecoderReuseEvaluation.REUSE_RESULT_NO;
import static androidx.media3.exoplayer.DecoderReuseEvaluation.REUSE_RESULT_YES_WITHOUT_RECONFIGURATION;

import android.os.Handler;
import android.view.Surface;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.TraceUtil;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.CryptoConfig;
import androidx.media3.decoder.DecoderException;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import androidx.media3.exoplayer.DecoderReuseEvaluation;
import androidx.media3.exoplayer.RendererCapabilities;
import androidx.media3.exoplayer.video.DecoderVideoRenderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import java.util.Objects;

/**
 * ExoPlayer renderer that decodes video with our vendored FFmpeg
 * extension and converts the YUV frame to RGB via a GLES2 shader before
 * presenting on the output Surface. Slotted ahead of
 * MediaCodecVideoRenderer via EXTENSION_RENDERER_MODE_PREFER so files
 * that exceed platform decoder caps (deep DPB, iOS yuvj420p) work on
 * devices where Media3's hardware path fails.
 */
@UnstableApi
public final class FfmpegVideoRenderer extends DecoderVideoRenderer {

  private static final String TAG = "FfmpegVideoRenderer";
  private static final int DEFAULT_NUM_INPUT_BUFFERS = 4;
  // iOS H.264 records with max_num_reorder_frames up to 16, and our
  // shouldBeSkipped-on-EAGAIN path consumes one output buffer per
  // input until the DPB fills. With 8 buffers the pipeline ran out
  // before steady state and the renderer dropped frames waiting on
  // free output buffers; 16 covers the worst iOS reorder shape.
  private static final int DEFAULT_NUM_OUTPUT_BUFFERS = 16;
  // 480x848 baseline; the decoder grows the buffer if a packet exceeds.
  private static final int DEFAULT_INPUT_BUFFER_SIZE = 256 * 1024;

  private final int threads;
  private final int numInputBuffers;
  private final int numOutputBuffers;
  private final FfmpegSurfaceSizer surfaceSizer;

  @Nullable private FfmpegVideoDecoder decoder;
  @Nullable private FfmpegOutputSurface outputSurface;
  @Nullable private Surface currentSurface;
  private int surfaceWidth = -1;
  private int surfaceHeight = -1;
  private int surfaceRotation = 0;

  public FfmpegVideoRenderer(
      long allowedJoiningTimeMs,
      @Nullable Handler eventHandler,
      @Nullable VideoRendererEventListener eventListener,
      int maxDroppedFramesToNotify,
      FfmpegSurfaceSizer surfaceSizer) {
    this(
        allowedJoiningTimeMs,
        eventHandler,
        eventListener,
        maxDroppedFramesToNotify,
        surfaceSizer,
        /* threads= */ 0,
        DEFAULT_NUM_INPUT_BUFFERS,
        DEFAULT_NUM_OUTPUT_BUFFERS);
  }

  public FfmpegVideoRenderer(
      long allowedJoiningTimeMs,
      @Nullable Handler eventHandler,
      @Nullable VideoRendererEventListener eventListener,
      int maxDroppedFramesToNotify,
      FfmpegSurfaceSizer surfaceSizer,
      int threads,
      int numInputBuffers,
      int numOutputBuffers) {
    super(allowedJoiningTimeMs, eventHandler, eventListener, maxDroppedFramesToNotify);
    this.threads = threads;
    this.numInputBuffers = numInputBuffers;
    this.numOutputBuffers = numOutputBuffers;
    this.surfaceSizer = surfaceSizer;
  }

  @Override
  public String getName() {
    return TAG;
  }

  @Override
  public @Capabilities int supportsFormat(Format format) {
    String mime = format.sampleMimeType;
    if (!FfmpegLibrary.isAvailable() || mime == null || !MimeTypes.isVideo(mime)) {
      return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_TYPE);
    }
    if (!FfmpegLibrary.supportsFormat(mime)) {
      return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_SUBTYPE);
    }
    if (format.cryptoType != C.CRYPTO_TYPE_NONE) {
      return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_DRM);
    }
    return RendererCapabilities.create(
        C.FORMAT_HANDLED, ADAPTIVE_SEAMLESS, TUNNELING_NOT_SUPPORTED);
  }

  @Override
  protected FfmpegVideoDecoder createDecoder(Format format, @Nullable CryptoConfig cryptoConfig)
      throws FfmpegDecoderException {
    TraceUtil.beginSection("createFfmpegVideoDecoder");
    int initialInputBufferSize =
        format.maxInputSize != Format.NO_VALUE ? format.maxInputSize : DEFAULT_INPUT_BUFFER_SIZE;
    FfmpegVideoDecoder d =
        new FfmpegVideoDecoder(
            format, numInputBuffers, numOutputBuffers, initialInputBufferSize, threads);
    decoder = d;
    TraceUtil.endSection();
    return d;
  }

  /// Pre-swap buffer dims for 90°/270° rotated streams so the
  /// {@code maybeNotifyVideoSizeChanged} call inside the base
  /// renderOutputBuffer reports DISPLAY-orientation dimensions (matching
  /// what MediaCodecVideoRenderer does for the hardware path). Without
  /// this swap, portrait iOS videos report their coded landscape size
  /// and the downstream compositor lays out the Flutter texture
  /// rotated.
  @Override
  protected void renderOutputBuffer(
      VideoDecoderOutputBuffer outputBuffer, long presentationTimeUs, Format outputFormat)
      throws DecoderException {
    if (outputFormat != null
        && (outputFormat.rotationDegrees == 90 || outputFormat.rotationDegrees == 270)
        && outputBuffer.width != outputBuffer.height) {
      int tmp = outputBuffer.width;
      outputBuffer.width = outputBuffer.height;
      outputBuffer.height = tmp;
    }
    super.renderOutputBuffer(outputBuffer, presentationTimeUs, outputFormat);
  }

  @Override
  protected void renderOutputBufferToSurface(
      VideoDecoderOutputBuffer outputBuffer, Surface surface) throws FfmpegDecoderException {
    int rotation = outputBuffer.format != null ? outputBuffer.format.rotationDegrees : 0;
    if (outputSurface == null
        || currentSurface != surface
        || surfaceWidth != outputBuffer.width
        || surfaceHeight != outputBuffer.height
        || surfaceRotation != rotation) {
      releaseOutputSurface();
      // Resize the SurfaceTexture before creating the EGL window
      // surface — the EGL surface inherits the SurfaceTexture's buffer
      // dimensions at creation and won't auto-resize later.
      surfaceSizer.resize(outputBuffer.width, outputBuffer.height);
      outputSurface = new FfmpegOutputSurface();
      outputSurface.configure(surface, outputBuffer.width, outputBuffer.height, rotation);
      currentSurface = surface;
      surfaceWidth = outputBuffer.width;
      surfaceHeight = outputBuffer.height;
      surfaceRotation = rotation;
    }
    try {
      outputSurface.render(outputBuffer, rotation);
    } finally {
      outputBuffer.release();
    }
  }

  @Override
  protected void setDecoderOutputMode(@C.VideoOutputMode int outputMode) {
    if (decoder != null) {
      decoder.setOutputMode(outputMode);
    }
  }

  @Override
  protected DecoderReuseEvaluation canReuseDecoder(
      String decoderName, Format oldFormat, Format newFormat) {
    boolean sameMime = Objects.equals(oldFormat.sampleMimeType, newFormat.sampleMimeType);
    return new DecoderReuseEvaluation(
        decoderName,
        oldFormat,
        newFormat,
        sameMime ? REUSE_RESULT_YES_WITHOUT_RECONFIGURATION : REUSE_RESULT_NO,
        sameMime ? 0 : DISCARD_REASON_MIME_TYPE_CHANGED);
  }

  @Override
  protected void onDisabled() {
    releaseOutputSurface();
    decoder = null;
    super.onDisabled();
  }

  private void releaseOutputSurface() {
    if (outputSurface != null) {
      outputSurface.release();
      outputSurface = null;
    }
    currentSurface = null;
    surfaceWidth = -1;
    surfaceHeight = -1;
    surfaceRotation = 0;
  }
}
