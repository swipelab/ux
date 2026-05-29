/*
 * Adapted from Media3's SimpleDecoder (Apache 2.0, Copyright 2016 The
 * Android Open Source Project) under the LICENSE-2.0:
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Adds an end-of-stream drain hook. Media3's SimpleDecoder short-
 * circuits the EOS input and never invokes the subclass decode(), so
 * libavcodec's reorder buffer (up to ~16 frames for iOS H.264) is
 * never drained — the last frames of a clip are lost on first
 * play-through. This subclass extends the decode loop with a
 * draining state: when EOS hits, signalEndOfInput() tells libavcodec
 * to flush its reorder queue, then drainAtEndOfStream() is called on
 * successive output buffers until it reports DRAIN_DONE, at which
 * point the EOS flag is finally attached.
 *
 * Everything else mirrors SimpleDecoder verbatim. Keeping the
 * mirror tight makes it cheap to adopt upstream improvements.
 */
package io.swipelab.ux.video.ffmpeg;

import androidx.annotation.CallSuper;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.Decoder;
import androidx.media3.decoder.DecoderException;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.decoder.DecoderOutputBuffer;
import java.util.ArrayDeque;

@UnstableApi
abstract class FfmpegSimpleDecoder<
        I extends DecoderInputBuffer, O extends DecoderOutputBuffer, E extends DecoderException>
    implements Decoder<I, O, E> {

  /** Subclass produced a frame into the supplied output buffer; keep calling. */
  protected static final int DRAIN_PRODUCED_FRAME = 0;
  /** Subclass has no more buffered frames; output buffer untouched, attach EOS. */
  protected static final int DRAIN_DONE = 1;
  /** Fatal drain error; output buffer untouched, abort the decoder. */
  protected static final int DRAIN_ERROR = 2;

  private final Thread decodeThread;
  private final Object lock;
  private final ArrayDeque<I> queuedInputBuffers;
  private final ArrayDeque<O> queuedOutputBuffers;
  private final I[] availableInputBuffers;
  private final O[] availableOutputBuffers;

  private int availableInputBufferCount;
  private int availableOutputBufferCount;
  @Nullable private I dequeuedInputBuffer;

  @Nullable private E exception;
  private boolean flushed;
  private boolean released;
  private int skippedOutputBufferCount;
  private long outputStartTimeUs;
  // True between receiving an EOS input and the drain hook returning
  // DRAIN_DONE. During this window the decode loop fires whenever an
  // output buffer is available, regardless of the input queue.
  private boolean draining;

  protected FfmpegSimpleDecoder(I[] inputBuffers, O[] outputBuffers) {
    lock = new Object();
    outputStartTimeUs = C.TIME_UNSET;
    queuedInputBuffers = new ArrayDeque<>();
    queuedOutputBuffers = new ArrayDeque<>();
    availableInputBuffers = inputBuffers;
    availableInputBufferCount = inputBuffers.length;
    for (int i = 0; i < availableInputBufferCount; i++) {
      availableInputBuffers[i] = createInputBuffer();
    }
    availableOutputBuffers = outputBuffers;
    availableOutputBufferCount = outputBuffers.length;
    for (int i = 0; i < availableOutputBufferCount; i++) {
      availableOutputBuffers[i] = createOutputBuffer();
    }
    decodeThread =
        new Thread("UxFfmpegSimpleDecoder") {
          @Override
          public void run() {
            FfmpegSimpleDecoder.this.runLoop();
          }
        };
    decodeThread.start();
  }

  protected final void setInitialInputBufferSize(int size) {
    for (I inputBuffer : availableInputBuffers) {
      inputBuffer.ensureSpaceForWrite(size);
    }
  }

  protected final boolean isAtLeastOutputStartTimeUs(long timeUs) {
    synchronized (lock) {
      return outputStartTimeUs == C.TIME_UNSET || timeUs >= outputStartTimeUs;
    }
  }

  @Override
  public final void setOutputStartTimeUs(long outputStartTimeUs) {
    synchronized (lock) {
      this.outputStartTimeUs = outputStartTimeUs;
    }
  }

  @Override
  @Nullable
  public final I dequeueInputBuffer() throws E {
    synchronized (lock) {
      maybeThrowException();
      dequeuedInputBuffer =
          availableInputBufferCount == 0
              ? null
              : availableInputBuffers[--availableInputBufferCount];
      return dequeuedInputBuffer;
    }
  }

  @Override
  public final void queueInputBuffer(I inputBuffer) throws E {
    synchronized (lock) {
      maybeThrowException();
      queuedInputBuffers.addLast(inputBuffer);
      maybeNotifyDecodeLoop();
      dequeuedInputBuffer = null;
    }
  }

  @Override
  @Nullable
  public final O dequeueOutputBuffer() throws E {
    synchronized (lock) {
      maybeThrowException();
      if (queuedOutputBuffers.isEmpty()) {
        return null;
      }
      return queuedOutputBuffers.removeFirst();
    }
  }

  @CallSuper
  protected void releaseOutputBuffer(O outputBuffer) {
    synchronized (lock) {
      outputBuffer.clear();
      availableOutputBuffers[availableOutputBufferCount++] = outputBuffer;
      maybeNotifyDecodeLoop();
    }
  }

  @Override
  public final void flush() {
    synchronized (lock) {
      flushed = true;
      draining = false;
      skippedOutputBufferCount = 0;
      if (dequeuedInputBuffer != null) {
        releaseInputBufferInternal(dequeuedInputBuffer);
        dequeuedInputBuffer = null;
      }
      while (!queuedInputBuffers.isEmpty()) {
        releaseInputBufferInternal(queuedInputBuffers.removeFirst());
      }
      while (!queuedOutputBuffers.isEmpty()) {
        queuedOutputBuffers.removeFirst().release();
      }
    }
  }

  @CallSuper
  @Override
  public void release() {
    synchronized (lock) {
      released = true;
      lock.notify();
    }
    try {
      decodeThread.join();
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }

  private void maybeThrowException() throws E {
    @Nullable E e = this.exception;
    if (e != null) {
      throw e;
    }
  }

  private void maybeNotifyDecodeLoop() {
    if (canDecodeBuffer()) {
      lock.notify();
    }
  }

  private void runLoop() {
    try {
      while (decodeOne()) {
        // tight loop
      }
    } catch (InterruptedException e) {
      throw new IllegalStateException(e);
    }
  }

  private boolean decodeOne() throws InterruptedException {
    @Nullable I inputBuffer;
    O outputBuffer;
    boolean resetDecoder;
    boolean drainingLocal;

    synchronized (lock) {
      while (!released && !canDecodeBuffer()) {
        lock.wait();
      }
      if (released) {
        return false;
      }
      outputBuffer = availableOutputBuffers[--availableOutputBufferCount];
      resetDecoder = flushed;
      flushed = false;
      drainingLocal = draining;
      if (drainingLocal) {
        inputBuffer = null;
      } else {
        inputBuffer = queuedInputBuffers.removeFirst();
      }
    }

    @Nullable E iterationException = null;
    boolean attachEosFlag = false;

    if (drainingLocal) {
      // Continuation of an EOS drain that started earlier.
      int drainResult;
      try {
        drainResult = drainAtEndOfStream(outputBuffer);
      } catch (RuntimeException e) {
        drainResult = DRAIN_ERROR;
        iterationException = createUnexpectedDecodeException(e);
      } catch (OutOfMemoryError e) {
        drainResult = DRAIN_ERROR;
        iterationException = createUnexpectedDecodeException(e);
      }
      if (drainResult == DRAIN_DONE) {
        attachEosFlag = true;
        synchronized (lock) {
          draining = false;
        }
      } else if (drainResult == DRAIN_ERROR && iterationException == null) {
        iterationException = createUnexpectedDecodeException(
            new IllegalStateException("EOS drain reported DRAIN_ERROR"));
      }
    } else if (inputBuffer.isEndOfStream()) {
      // First time we see EOS — tell libavcodec to flush its reorder
      // buffer, then drain one frame immediately into this output
      // buffer. If no buffered frames remain we attach EOS now;
      // otherwise the next loop iteration runs the draining branch.
      try {
        signalEndOfInput();
      } catch (RuntimeException e) {
        iterationException = createUnexpectedDecodeException(e);
      }
      int drainResult = DRAIN_DONE;
      if (iterationException == null) {
        try {
          drainResult = drainAtEndOfStream(outputBuffer);
        } catch (RuntimeException e) {
          drainResult = DRAIN_ERROR;
          iterationException = createUnexpectedDecodeException(e);
        }
      }
      if (drainResult == DRAIN_PRODUCED_FRAME) {
        synchronized (lock) {
          draining = true;
        }
      } else if (drainResult == DRAIN_DONE) {
        attachEosFlag = true;
      } else if (iterationException == null) {
        iterationException = createUnexpectedDecodeException(
            new IllegalStateException("EOS drain reported DRAIN_ERROR"));
      }
    } else {
      // Normal decode path — same shape as SimpleDecoder.
      outputBuffer.timeUs = inputBuffer.timeUs;
      if (inputBuffer.isFirstSample()) {
        outputBuffer.addFlag(C.BUFFER_FLAG_FIRST_SAMPLE);
      }
      if (!isAtLeastOutputStartTimeUs(inputBuffer.timeUs)) {
        outputBuffer.shouldBeSkipped = true;
      }
      try {
        iterationException = decode(inputBuffer, outputBuffer, resetDecoder);
      } catch (RuntimeException e) {
        iterationException = createUnexpectedDecodeException(e);
      } catch (OutOfMemoryError e) {
        iterationException = createUnexpectedDecodeException(e);
      }
    }

    if (iterationException != null) {
      synchronized (lock) {
        this.exception = iterationException;
      }
      return false;
    }
    if (attachEosFlag) {
      outputBuffer.addFlag(C.BUFFER_FLAG_END_OF_STREAM);
    }

    synchronized (lock) {
      if (flushed) {
        outputBuffer.release();
      } else if (outputBuffer.shouldBeSkipped) {
        skippedOutputBufferCount++;
        outputBuffer.release();
      } else {
        outputBuffer.skippedOutputBufferCount = skippedOutputBufferCount;
        skippedOutputBufferCount = 0;
        queuedOutputBuffers.addLast(outputBuffer);
      }
      if (inputBuffer != null) {
        releaseInputBufferInternal(inputBuffer);
      }
    }
    return true;
  }

  private boolean canDecodeBuffer() {
    if (draining) {
      return availableOutputBufferCount > 0;
    }
    return !queuedInputBuffers.isEmpty() && availableOutputBufferCount > 0;
  }

  private void releaseInputBufferInternal(I inputBuffer) {
    inputBuffer.clear();
    availableInputBuffers[availableInputBufferCount++] = inputBuffer;
  }

  protected abstract I createInputBuffer();

  protected abstract O createOutputBuffer();

  protected abstract E createUnexpectedDecodeException(Throwable error);

  /**
   * Decodes the {@code inputBuffer} and stores any decoded output in
   * {@code outputBuffer}. Same contract as Media3's
   * {@code SimpleDecoder.decode}.
   */
  @Nullable
  protected abstract E decode(I inputBuffer, O outputBuffer, boolean reset);

  /**
   * Called once when an end-of-stream input buffer arrives, before
   * the first call to {@link #drainAtEndOfStream}. Subclass should
   * tell its backend decoder to flush its internal queue —
   * {@code avcodec_send_packet(ctx, NULL)} for libavcodec.
   */
  protected abstract void signalEndOfInput();

  /**
   * Pulls one buffered frame from the backend decoder into the
   * supplied output buffer. Called once per available output buffer
   * after EOS until it reports {@link #DRAIN_DONE}; the decode loop
   * then attaches {@code BUFFER_FLAG_END_OF_STREAM} to that same
   * output buffer before queueing it.
   *
   * @return one of {@link #DRAIN_PRODUCED_FRAME}, {@link #DRAIN_DONE},
   *     {@link #DRAIN_ERROR}.
   */
  protected abstract int drainAtEndOfStream(O outputBuffer);
}
