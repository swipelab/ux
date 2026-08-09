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

/**
 * The same mask on the grid its inference input sits on, from the upright grid
 * a segmenter given [rotation] answers on.
 */
fun PersonMaskPixels.onInputGrid(rotation: CameraFrameRotation): PersonMaskPixels {
    val turned = rotation == CameraFrameRotation.DEGREES_90 ||
        rotation == CameraFrameRotation.DEGREES_270
    val inputWidth = if (turned) height else width
    val inputHeight = if (turned) width else height
    val source = confidence
    val mapped = FloatBuffer.allocate(inputWidth * inputHeight)
    for (y in 0 until inputHeight) {
        for (x in 0 until inputWidth) {
            val index = when (rotation) {
                CameraFrameRotation.DEGREES_0 -> y * width + x
                CameraFrameRotation.DEGREES_90 -> x * width + (inputHeight - 1 - y)
                CameraFrameRotation.DEGREES_180 ->
                    (inputHeight - 1 - y) * width + (inputWidth - 1 - x)
                CameraFrameRotation.DEGREES_270 -> (inputWidth - 1 - x) * width + y
            }
            mapped.put(y * inputWidth + x, source.get(index))
        }
    }
    return PersonMaskPixels(inputWidth, inputHeight, mapped)
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

/**
 * Why the mask cannot be applied over a [frameWidth]×[frameHeight] frame, or
 * `null` when it can.
 */
internal fun CameraMask.rejectionOver(frameWidth: Int, frameHeight: Int): CameraMaskRejection? {
    if (width <= 0 || height <= 0) return CameraMaskRejection.ZERO_DIMENSIONED
    if (sourceRect != CameraFrameRect(0, 0, frameWidth, frameHeight)) {
        return CameraMaskRejection.SOURCE_RECT_MISMATCH
    }
    if (!hasValidStorage) return CameraMaskRejection.INVALID_STORAGE
    if (isAllZero()) return CameraMaskRejection.EMPTY
    return null
}

private fun CameraMask.isAllZero(): Boolean {
    val confidence = confidenceView()
    for (index in 0 until width * height) {
        if (confidence.get(index) != 0f) return false
    }
    return true
}

private fun hasMaskStorage(width: Int, height: Int, confidence: FloatBuffer): Boolean {
    if (width <= 0 || height <= 0) return true
    val samples = width.toLong() * height.toLong()
    return samples <= Int.MAX_VALUE && samples <= confidence.limit().toLong()
}
