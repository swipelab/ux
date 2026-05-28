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

import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.DecoderException;

@UnstableApi
public final class FfmpegDecoderException extends DecoderException {
  public FfmpegDecoderException(String message) {
    super(message);
  }

  public FfmpegDecoderException(String message, Throwable cause) {
    super(message, cause);
  }
}
