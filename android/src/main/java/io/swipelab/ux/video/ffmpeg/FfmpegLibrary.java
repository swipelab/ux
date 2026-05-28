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
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;

/**
 * Loads libffmpegJNI.so and answers capability queries against the
 * statically-linked FFmpeg build. The current native build only enables
 * the H.264 decoder; queries for other MIME types return false.
 */
@UnstableApi
public final class FfmpegLibrary {

  private static final Object lock = new Object();
  private static boolean attempted;
  private static boolean available;

  private FfmpegLibrary() {}

  public static boolean isAvailable() {
    synchronized (lock) {
      if (attempted) {
        return available;
      }
      attempted = true;
      try {
        System.loadLibrary("ffmpegJNI");
        available = true;
      } catch (UnsatisfiedLinkError e) {
        android.util.Log.w(
            "UxFfmpeg",
            "libffmpegJNI.so missing for this ABI; falling back to MediaCodec");
        available = false;
      }
      return available;
    }
  }

  public static String getVersion() {
    return isAvailable() ? ffmpegGetVersion() : "";
  }

  public static int getInputBufferPaddingSize() {
    return isAvailable() ? ffmpegGetInputBufferPaddingSize() : 0;
  }

  /** Whether the given MIME type maps to a decoder built into this libffmpegJNI.so. */
  public static boolean supportsFormat(@Nullable String mimeType) {
    if (mimeType == null || !isAvailable()) {
      return false;
    }
    String codecName = getCodecName(mimeType);
    if (codecName == null) {
      return false;
    }
    return ffmpegHasDecoder(codecName);
  }

  /**
   * FFmpeg decoder name for the given MIME type, or null if no mapping
   * exists. Only video codecs are wired up; the JNI build excludes
   * audio decoders entirely.
   */
  @Nullable
  public static String getCodecName(String mimeType) {
    switch (mimeType) {
      case MimeTypes.VIDEO_H264:
        return "h264";
      default:
        return null;
    }
  }

  private static native String ffmpegGetVersion();

  private static native int ffmpegGetInputBufferPaddingSize();

  private static native boolean ffmpegHasDecoder(String codecName);
}
