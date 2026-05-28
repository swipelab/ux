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

/**
 * Resizes the SurfaceTexture backing the player's output Surface
 * before the FFmpeg renderer's EGL window surface is created. Without
 * this the SurfaceTexture's default buffer size is whatever
 * implementation default Android picked (often 1×1) — the EGL surface
 * inherits that, our quad renders into one pixel, and the compositor
 * stretches it across the Flutter texture.
 *
 * <p>The compositor's player listener also calls
 * setDefaultBufferSize, but only on the main thread after the player
 * fires onVideoSizeChanged. By then the FFmpeg renderer has already
 * created its EGL window surface on the player thread. Threading this
 * hook through ensures resize-before-window-create.
 */
@UnstableApi
public interface FfmpegSurfaceSizer {
  void resize(int width, int height);
}
