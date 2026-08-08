package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer

/** A region of a frame's pixels, top-left origin, pre-rotation. */
data class CameraFrameRect(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
)

/**
 * A person mask as an inference answers it: one confidence per pixel,
 * row-major, 1 the person and 0 the background.
 */
class PersonMaskPixels(
    val width: Int,
    val height: Int,
    confidence: FloatBuffer,
) {
    private val samples: FloatBuffer = confidence.asReadOnlyBuffer()

    val confidence: FloatBuffer get() = samples.asReadOnlyBuffer()

    init {
        require(hasMaskStorage(width, height, samples))
    }
}

/** A single-channel person mask over one camera frame. */
class CameraMask(
    confidence: FloatBuffer,

    /**
     * The mask's own grid, whose aspect does not track the frame's: the whole
     * buffer stretches onto [sourceRect] with independent x and y scales.
     */
    val width: Int,
    val height: Int,

    /** The region of the frame's planes the mask was produced against. */
    val sourceRect: CameraFrameRect,

    /** The producer generation the inference was submitted under. */
    val generation: Int,
) {
    private val samples: FloatBuffer = confidence.asReadOnlyBuffer()

    val confidence: FloatBuffer get() = samples.asReadOnlyBuffer()

    internal val hasValidStorage: Boolean = hasMaskStorage(width, height, samples)

    internal fun confidenceView(): FloatBuffer = samples.asReadOnlyBuffer()
}

private fun hasMaskStorage(width: Int, height: Int, confidence: FloatBuffer): Boolean {
    if (width <= 0 || height <= 0) return true
    val samples = width.toLong() * height.toLong()
    return samples <= Int.MAX_VALUE && samples <= confidence.limit().toLong()
}
