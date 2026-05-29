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

import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.common.util.Util;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.decoder.SimpleDecoder;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import java.nio.ByteBuffer;
import java.util.List;

/**
 * FFmpeg H.264 video decoder. Mirrors the Media3 audio pattern but
 * targets {@link VideoDecoderOutputBuffer}. Two-step send/receive maps
 * directly onto libavcodec's avcodec_send_packet / avcodec_receive_frame
 * lifecycle so we can drain multiple reordered frames out of a single
 * input packet.
 *
 * <h3>Known limits</h3>
 * <ul>
 *   <li><b>EOS trailing frames.</b> Media3's {@code SimpleDecoder}
 *   base class special-cases the end-of-stream input buffer and
 *   never invokes our {@code decode()} for it, so libavcodec's
 *   reorder buffer (~16 frames for iOS H.264 High@3.1) is never
 *   drained with {@code avcodec_send_packet(NULL)}. The last ~500 ms
 *   of a clip can be truncated on first play-through. Replay via
 *   {@code REPEAT_MODE_ONE} or {@code seekTo(0)} hits
 *   {@code avcodec_flush_buffers} which clears the queue, so the
 *   second play and onwards are full-length.</li>
 *   <li><b>Colorspace heuristic.</b> When the bitstream's
 *   {@code colorspace}/{@code primaries}/{@code transfer} are all
 *   unspecified we fall back to a size-based guess (BT.709 for >=
 *   720p, BT.601 below). iPhone 6/7-era 1080p clips that recorded
 *   BT.601 with unspecified metadata get mislabelled — skin tones
 *   are slightly oversaturated. Modern iOS sets {@code bt709}
 *   explicitly so trusting the bitstream is correct for almost
 *   everything in circulation today.</li>
 * </ul>
 */
@UnstableApi
public final class FfmpegVideoDecoder
    extends SimpleDecoder<
        DecoderInputBuffer, VideoDecoderOutputBuffer, FfmpegDecoderException> {

  // Mirrored from ffmpeg_jni.cc.
  private static final int VIDEO_DECODER_SUCCESS = 0;
  private static final int VIDEO_DECODER_ERROR_INVALID_DATA = -1;
  private static final int VIDEO_DECODER_ERROR_OTHER = -2;
  private static final int VIDEO_DECODER_READ_AGAIN = -3;

  private final String codecName;
  @Nullable private final byte[] extraData;
  private final long nativeContext;
  private volatile @C.VideoOutputMode int outputMode;

  public FfmpegVideoDecoder(
      Format format, int numInputBuffers, int numOutputBuffers, int initialInputBufferSize, int threads)
      throws FfmpegDecoderException {
    super(
        new DecoderInputBuffer[numInputBuffers],
        new VideoDecoderOutputBuffer[numOutputBuffers]);
    if (!FfmpegLibrary.isAvailable()) {
      throw new FfmpegDecoderException("Failed to load decoder native libraries.");
    }
    String mime = format.sampleMimeType;
    if (mime == null) {
      throw new FfmpegDecoderException("Format has null sampleMimeType.");
    }
    String name = FfmpegLibrary.getCodecName(mime);
    if (name == null) {
      throw new FfmpegDecoderException("No FFmpeg codec mapped for " + mime);
    }
    codecName = name;
    extraData = flattenInitializationData(format.initializationData);
    nativeContext = ffmpegVideoInitialize(codecName, extraData, threads);
    if (nativeContext == 0) {
      throw new FfmpegDecoderException("Initialization failed.");
    }
    setInitialInputBufferSize(initialInputBufferSize);
  }

  @Override
  public String getName() {
    return "ffmpeg" + FfmpegLibrary.getVersion() + "-" + codecName;
  }

  @Override
  protected DecoderInputBuffer createInputBuffer() {
    return new DecoderInputBuffer(
        DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_DIRECT,
        FfmpegLibrary.getInputBufferPaddingSize());
  }

  @Override
  protected VideoDecoderOutputBuffer createOutputBuffer() {
    return new VideoDecoderOutputBuffer(this::releaseOutputBuffer);
  }

  @Override
  protected FfmpegDecoderException createUnexpectedDecodeException(Throwable error) {
    return new FfmpegDecoderException("Unexpected decode error", error);
  }

  @Override
  @Nullable
  protected FfmpegDecoderException decode(
      DecoderInputBuffer inputBuffer, VideoDecoderOutputBuffer outputBuffer, boolean reset) {
    if (reset) {
      ffmpegVideoFlush(nativeContext);
    }

    ByteBuffer inputData = Util.castNonNull(inputBuffer.data);
    int inputSize = inputData.limit();
    int sendResult =
        ffmpegVideoSendPacket(nativeContext, inputData, inputSize, inputBuffer.timeUs);
    if (sendResult == VIDEO_DECODER_ERROR_INVALID_DATA) {
      // Treat invalid bitstream as non-fatal — match MediaCodec behavior.
      outputBuffer.shouldBeSkipped = true;
      return null;
    } else if (sendResult == VIDEO_DECODER_ERROR_OTHER) {
      return new FfmpegDecoderException("avcodec_send_packet failed (see logcat).");
    }
    // sendResult is VIDEO_DECODER_SUCCESS or VIDEO_DECODER_READ_AGAIN.
    // EAGAIN on send means the decoder needs to be drained first — but
    // SimpleDecoder gives us one input + one output per decode() call,
    // so on the next iteration we'll be called with a fresh output
    // buffer and try receive again. Drop this input on EAGAIN.

    // init seeds outputBuffer.timeUs from the input PTS; the native
    // receive path overwrites it with the decoded frame's true
    // display-order PTS (recovered from libavcodec) before returning
    // success.
    outputBuffer.init(inputBuffer.timeUs, outputMode, /* supplementalData= */ null);
    outputBuffer.format = inputBuffer.format;
    int receiveResult = ffmpegVideoReceiveFrame(nativeContext, outputBuffer);
    if (receiveResult == VIDEO_DECODER_READ_AGAIN) {
      // No frame ready yet (decoder still building reorder buffer).
      // Skip this output buffer; subsequent send/receive cycles will
      // drain frames once the pipeline fills.
      outputBuffer.shouldBeSkipped = true;
      return null;
    } else if (receiveResult == VIDEO_DECODER_ERROR_INVALID_DATA) {
      outputBuffer.shouldBeSkipped = true;
      return null;
    } else if (receiveResult == VIDEO_DECODER_ERROR_OTHER) {
      return new FfmpegDecoderException("avcodec_receive_frame failed (see logcat).");
    }
    return null;
  }

  @Override
  public void release() {
    super.release();
    ffmpegVideoRelease(nativeContext);
  }

  public void setOutputMode(@C.VideoOutputMode int outputMode) {
    this.outputMode = outputMode;
  }

  /**
   * Coalesces the codec-specific data into one contiguous byte array
   * for FFmpeg's extradata pointer. For AVC the MP4 extractor delivers
   * a single avcC blob in slot 0; some demuxers split SPS/PPS into
   * separate NAL units (Annex B). In both cases libavcodec auto-detects
   * the layout from the first byte.
   */
  @Nullable
  private static byte[] flattenInitializationData(List<byte[]> initializationData) {
    if (initializationData == null || initializationData.isEmpty()) {
      return null;
    }
    if (initializationData.size() == 1) {
      return initializationData.get(0);
    }
    int total = 0;
    for (byte[] part : initializationData) total += part.length;
    byte[] out = new byte[total];
    int off = 0;
    for (byte[] part : initializationData) {
      System.arraycopy(part, 0, out, off, part.length);
      off += part.length;
    }
    return out;
  }

  private native long ffmpegVideoInitialize(
      String codecName, @Nullable byte[] extraData, int threads);

  private native int ffmpegVideoSendPacket(
      long context, ByteBuffer inputData, int inputSize, long ptsUs);

  private native int ffmpegVideoReceiveFrame(long context, VideoDecoderOutputBuffer outputBuffer);

  private native void ffmpegVideoFlush(long context);

  private native void ffmpegVideoRelease(long context);
}
