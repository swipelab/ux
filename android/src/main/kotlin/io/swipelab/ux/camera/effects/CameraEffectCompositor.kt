package io.swipelab.ux.camera.effects

import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.FloatBuffer
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * One CPU render pipeline per effect: reads the input frame's I420 planes,
 * effects the background under the person mask, and never lets a raw frame
 * out.
 */
class CameraEffectCompositor(
    private val effect: CameraEffect,
    private val pools: CameraEffectBufferPools = FrameBufferPools(),
) {
    companion object {
        const val DIM_FACTOR = 0.5
    }

    private val dimNumerator = (DIM_FACTOR * 256).roundToInt()

    private val lock = Any()

    private class Geometry(
        val width: Int,
        val height: Int,
        val pool: CameraEffectBufferPool?,
        val scratch: RenderScratch,
    )

    private var geometry: Geometry? = null
    private var lastGood: CameraEffectBuffer? = null
    private var black: CameraEffectBuffer? = null

    fun composite(frame: CameraFrame, mask: CameraMask?): CompositeOutcome = synchronized(lock) {
        if (frame.width <= 0 || frame.height <= 0) {
            return substitution(frame, CameraCompositeSubstitution.MALFORMED_FRAME)
        }
        val planes = try {
            frame.planes()
        } catch (_: Exception) {
            return substitution(frame, CameraCompositeSubstitution.RENDER_FAILED)
        }
        if (!isWellFormed(frame, planes)) {
            return substitution(frame, CameraCompositeSubstitution.MALFORMED_FRAME)
        }
        val active = adopt(frame.width, frame.height)
        val output = active.pool?.take()
            ?: return substitution(frame, CameraCompositeSubstitution.POOL_UNAVAILABLE)
        val assessed = assess(mask, frame)
        try {
            render(planes, assessed.mask, assessed.confidence, active.scratch, output)
        } catch (_: Exception) {
            output.release()
            return substitution(frame, CameraCompositeSubstitution.RENDER_FAILED)
        }
        lastGood?.release()
        lastGood = output
        CompositeOutcome.Composited(published(output, frame), assessed.rejection)
    }

    private fun adopt(width: Int, height: Int): Geometry {
        val current = geometry
        if (current != null && current.width == width && current.height == height) {
            return current
        }
        lastGood?.release()
        lastGood = null
        black?.release()
        black = null
        return Geometry(
            width, height, pools.makePool(width, height), RenderScratch(width, height),
        ).also { geometry = it }
    }

    private fun render(
        planes: CameraFramePlanes,
        mask: CameraMask?,
        confidence: FloatBuffer?,
        scratch: RenderScratch,
        output: CameraEffectBuffer,
    ) {
        scratch.readInput(planes)
        when (effect) {
            CameraEffect.NONE -> scratch.copyInput()
            CameraEffect.BLUR -> scratch.blur()
            CameraEffect.DIM -> scratch.dim(dimNumerator)
        }
        if (mask != null) {
            scratch.prepareMask(mask, requireNotNull(confidence))
            scratch.blendPerson()
        }
        scratch.writeInto(output)
    }

    private fun isWellFormed(frame: CameraFrame, planes: CameraFramePlanes): Boolean {
        if (planes.width != frame.width || planes.height != frame.height) return false
        val chromaWidth = (planes.width + 1) / 2
        val chromaHeight = (planes.height + 1) / 2
        if (planes.strideY < planes.width) return false
        if (planes.strideU < chromaWidth || planes.strideV < chromaWidth) return false
        if (planes.dataY.capacity() < (planes.height - 1) * planes.strideY + planes.width) {
            return false
        }
        if (planes.dataU.capacity() < (chromaHeight - 1) * planes.strideU + chromaWidth) {
            return false
        }
        if (planes.dataV.capacity() < (chromaHeight - 1) * planes.strideV + chromaWidth) {
            return false
        }
        return true
    }

    private class AssessedMask(
        val mask: CameraMask?,
        val confidence: FloatBuffer?,
        val rejection: CameraMaskRejection?,
    )

    private fun assess(mask: CameraMask?, frame: CameraFrame): AssessedMask {
        if (mask == null) return AssessedMask(null, null, null)
        if (mask.width <= 0 || mask.height <= 0) {
            return AssessedMask(null, null, CameraMaskRejection.ZERO_DIMENSIONED)
        }
        if (mask.sourceRect != CameraFrameRect(0, 0, frame.width, frame.height)) {
            return AssessedMask(null, null, CameraMaskRejection.SOURCE_RECT_MISMATCH)
        }
        if (!mask.hasValidStorage) {
            return AssessedMask(null, null, CameraMaskRejection.INVALID_STORAGE)
        }
        val confidence = mask.confidenceView()
        if (isAllZero(mask, confidence)) {
            return AssessedMask(null, null, CameraMaskRejection.EMPTY)
        }
        return AssessedMask(mask, confidence, null)
    }

    private fun isAllZero(mask: CameraMask, confidence: FloatBuffer): Boolean {
        for (index in 0 until mask.width * mask.height) {
            if (confidence.get(index) != 0f) return false
        }
        return true
    }

    private fun substitution(
        frame: CameraFrame,
        reason: CameraCompositeSubstitution,
    ): CompositeOutcome {
        val good = lastGood
        if (good != null) {
            return CompositeOutcome.Substituted(published(good, frame), reason)
        }
        val substitute = black ?: makeBlackBuffer(
            maxOf(1, frame.width), maxOf(1, frame.height),
        ).also { black = it }
        return CompositeOutcome.Substituted(published(substitute, frame), reason)
    }

    /** Poolless, so a pool failure can always be answered. */
    private fun makeBlackBuffer(width: Int, height: Int): CameraEffectBuffer {
        val buffer = CameraEffectBuffer(null, width, height)
        buffer.fillBlack()
        return buffer
    }

    /**
     * The published frame carries a reference to [buffer]; releasing the
     * frame's planes is what returns the buffer to its pool.
     */
    private fun published(buffer: CameraEffectBuffer, from: CameraFrame): CameraFrame {
        buffer.retain()
        val planes = CameraFramePlanes(
            width = buffer.width,
            height = buffer.height,
            dataY = buffer.publishedY(),
            strideY = buffer.width,
            dataU = buffer.publishedU(),
            strideU = buffer.chromaWidth,
            dataV = buffer.publishedV(),
            strideV = buffer.chromaWidth,
            release = buffer::release,
        )
        return CameraFrame(
            width = buffer.width,
            height = buffer.height,
            rotation = from.rotation,
            timestampNs = from.timestampNs,
            source = { planes },
        )
    }
}

private const val LUMA_DOWNSCALE = 8
private const val CHROMA_DOWNSCALE = 4

/**
 * Each box pass adds ((2r+1)² − 1) / 12 to the variance per axis, so these
 * radii compose to sigma ≈ 2.2 on the downscaled grid.
 */
private val BOX_RADII = intArrayOf(2, 2, 1)

/** Per-geometry working memory, reused across composites one at a time. */
private class RenderScratch(val width: Int, val height: Int) {
    val chromaWidth = (width + 1) / 2
    val chromaHeight = (height + 1) / 2

    private val inY = ByteArray(width * height)
    private val inU = ByteArray(chromaWidth * chromaHeight)
    private val inV = ByteArray(chromaWidth * chromaHeight)
    private val outY = ByteArray(width * height)
    private val outU = ByteArray(chromaWidth * chromaHeight)
    private val outV = ByteArray(chromaWidth * chromaHeight)

    private val smallWidth = smallSize(width, LUMA_DOWNSCALE)
    private val smallHeight = smallSize(height, LUMA_DOWNSCALE)

    private val smallA = IntArray(smallWidth * smallHeight)
    private val smallB = IntArray(smallWidth * smallHeight)

    private val lumaRows = IntArray(smallHeight * width)
    private val chromaRows = IntArray(smallHeight * chromaWidth)

    private val lumaIndex0 = IntArray(width)
    private val lumaIndex1 = IntArray(width)
    private val lumaFrac = IntArray(width)
    private val chromaIndex0 = IntArray(chromaWidth)
    private val chromaIndex1 = IntArray(chromaWidth)
    private val chromaFrac = IntArray(chromaWidth)

    private var maskRows = IntArray(0)
    private var maskGridHeight = 0
    private var maskGridWidth = 0
    private val maskIndex0 = IntArray(width)
    private val maskIndex1 = IntArray(width)
    private val maskFrac = IntArray(width)

    init {
        fillMapping(width, smallWidth, lumaIndex0, lumaIndex1, lumaFrac)
        fillMapping(chromaWidth, smallWidth, chromaIndex0, chromaIndex1, chromaFrac)
    }

    fun readInput(planes: CameraFramePlanes) {
        copyPlane(planes.dataY, planes.strideY, width, height, inY)
        copyPlane(planes.dataU, planes.strideU, chromaWidth, chromaHeight, inU)
        copyPlane(planes.dataV, planes.strideV, chromaWidth, chromaHeight, inV)
    }

    fun copyInput() {
        System.arraycopy(inY, 0, outY, 0, inY.size)
        System.arraycopy(inU, 0, outU, 0, inU.size)
        System.arraycopy(inV, 0, outV, 0, inV.size)
    }

    fun dim(numerator: Int) {
        for (index in inY.indices) {
            outY[index] = (((inY[index].toInt() and 0xFF) * numerator) shr 8).toByte()
        }
        dimChroma(inU, outU, numerator)
        dimChroma(inV, outV, numerator)
    }

    private fun dimChroma(source: ByteArray, into: ByteArray, numerator: Int) {
        for (index in source.indices) {
            val offset = (source[index].toInt() and 0xFF) - 128
            into[index] = (128 + ((offset * numerator) shr 8)).toByte()
        }
    }

    fun blur() {
        blurPlane(
            inY, width, height, LUMA_DOWNSCALE,
            lumaRows, lumaIndex0, lumaIndex1, lumaFrac, outY,
        )
        blurPlane(
            inU, chromaWidth, chromaHeight, CHROMA_DOWNSCALE,
            chromaRows, chromaIndex0, chromaIndex1, chromaFrac, outU,
        )
        blurPlane(
            inV, chromaWidth, chromaHeight, CHROMA_DOWNSCALE,
            chromaRows, chromaIndex0, chromaIndex1, chromaFrac, outV,
        )
    }

    private fun blurPlane(
        source: ByteArray,
        planeWidth: Int,
        planeHeight: Int,
        factor: Int,
        rows: IntArray,
        index0: IntArray,
        index1: IntArray,
        frac: IntArray,
        into: ByteArray,
    ) {
        downscale(source, planeWidth, planeHeight, factor, smallA, smallWidth, smallHeight)
        for (radius in BOX_RADII) {
            boxRows(smallA, smallB, smallWidth, smallHeight, radius)
            boxColumns(smallB, smallA, smallWidth, smallHeight, radius)
        }
        for (row in 0 until smallHeight) {
            stretchRow(
                smallA, row * smallWidth,
                rows, row * planeWidth,
                index0, index1, frac, planeWidth,
            )
        }
        for (y in 0 until planeHeight) {
            val vertical = verticalMapping(2 * y + 1, smallHeight, 2 * planeHeight)
            val index = vertical shr 9
            val weight = vertical and 511
            val rowA = index * planeWidth
            val rowB = min(index + 1, smallHeight - 1) * planeWidth
            val base = y * planeWidth
            for (x in 0 until planeWidth) {
                val value = rows[rowA + x] * (256 - weight) + rows[rowB + x] * weight
                into[base + x] = ((value + 128) shr 8).toByte()
            }
        }
    }

    /** Stretches the mask's grid across the frame's width, one row per grid row. */
    fun prepareMask(mask: CameraMask, confidence: FloatBuffer) {
        if (mask.width != maskGridWidth) {
            maskGridWidth = mask.width
            fillMapping(width, mask.width, maskIndex0, maskIndex1, maskFrac)
        }
        maskGridHeight = mask.height
        if (maskRows.size < mask.height * width) {
            maskRows = IntArray(mask.height * width)
        }
        for (row in 0 until mask.height) {
            val sourceBase = row * mask.width
            val base = row * width
            for (x in 0 until width) {
                val weight = maskFrac[x]
                val near = confidence.get(sourceBase + maskIndex0[x])
                val far = confidence.get(sourceBase + maskIndex1[x])
                maskRows[base + x] = (near * (256 - weight) + far * weight + 0.5f).toInt()
            }
        }
    }

    fun blendPerson() {
        blendLuma(outY)
        blendChroma(inU, outU)
        blendChroma(inV, outV)
    }

    fun writeInto(output: CameraEffectBuffer) {
        output.write(outY, outU, outV)
    }

    private fun blendLuma(into: ByteArray) {
        for (y in 0 until height) {
            val vertical = verticalMapping(2 * y + 1, maskGridHeight, 2 * height)
            val index = vertical shr 9
            val weight = vertical and 511
            val rowA = index * width
            val rowB = min(index + 1, maskGridHeight - 1) * width
            val base = y * width
            for (x in 0 until width) {
                val alpha =
                    (maskRows[rowA + x] * (256 - weight) + maskRows[rowB + x] * weight) shr 8
                val person = inY[base + x].toInt() and 0xFF
                val background = into[base + x].toInt() and 0xFF
                into[base + x] =
                    ((person * alpha + background * (256 - alpha) + 128) shr 8).toByte()
            }
        }
    }

    private fun blendChroma(person: ByteArray, into: ByteArray) {
        for (y in 0 until chromaHeight) {
            val vertical = verticalMapping(4 * y + 2, maskGridHeight, 2 * height)
            val index = vertical shr 9
            val weight = vertical and 511
            val rowA = index * width
            val rowB = min(index + 1, maskGridHeight - 1) * width
            val base = y * chromaWidth
            for (x in 0 until chromaWidth) {
                val column = min(2 * x, width - 1)
                val alpha =
                    (maskRows[rowA + column] * (256 - weight) +
                        maskRows[rowB + column] * weight) shr 8
                val sample = person[base + x].toInt() and 0xFF
                val background = into[base + x].toInt() and 0xFF
                into[base + x] =
                    ((sample * alpha + background * (256 - alpha) + 128) shr 8).toByte()
            }
        }
    }

    private fun copyPlane(
        source: ByteBuffer,
        stride: Int,
        rowBytes: Int,
        rows: Int,
        into: ByteArray,
    ) {
        // Positioned through Buffer so the call binds to the signature that
        // exists below Android API 26.
        val cursor: Buffer = source.duplicate()
        val bytes = cursor as ByteBuffer
        for (row in 0 until rows) {
            cursor.position(row * stride)
            bytes.get(into, row * rowBytes, rowBytes)
        }
    }
}

private fun smallSize(size: Int, factor: Int): Int = maxOf(1, (size + factor - 1) / factor)

/**
 * Row index and 0..256 weight packed as `(row shl 9) or weight` for one
 * destination row's linear interpolation between two source rows.
 */
private fun verticalMapping(
    doubledCenter: Int,
    sourceRows: Int,
    doubledDestination: Int,
): Int {
    val position = doubledCenter.toDouble() * sourceRows / doubledDestination - 0.5
    var index = floor(position).toInt()
    var weight = ((position - index) * 256).roundToInt()
    if (index < 0) {
        index = 0
        weight = 0
    }
    if (index >= sourceRows - 1) {
        index = sourceRows - 1
        weight = 0
    }
    return (index shl 9) or weight
}

private fun fillMapping(
    destinationSize: Int,
    sourceSize: Int,
    index0: IntArray,
    index1: IntArray,
    frac: IntArray,
) {
    for (x in 0 until destinationSize) {
        val position = (x + 0.5) * sourceSize / destinationSize - 0.5
        var index = floor(position).toInt()
        var weight = ((position - index) * 256).roundToInt()
        if (index < 0) {
            index = 0
            weight = 0
        }
        if (index >= sourceSize - 1) {
            index = sourceSize - 1
            weight = 0
        }
        index0[x] = index
        index1[x] = min(index + 1, sourceSize - 1)
        frac[x] = weight
    }
}

private fun stretchRow(
    source: IntArray,
    sourceBase: Int,
    destination: IntArray,
    destinationBase: Int,
    index0: IntArray,
    index1: IntArray,
    frac: IntArray,
    count: Int,
) {
    for (x in 0 until count) {
        val weight = frac[x]
        destination[destinationBase + x] =
            (source[sourceBase + index0[x]] * (256 - weight) +
                source[sourceBase + index1[x]] * weight + 128) shr 8
    }
}

private fun downscale(
    source: ByteArray,
    sourceWidth: Int,
    sourceHeight: Int,
    factor: Int,
    destination: IntArray,
    destinationWidth: Int,
    destinationHeight: Int,
) {
    for (sy in 0 until destinationHeight) {
        val top = sy * factor
        val bottom = min(top + factor, sourceHeight)
        for (sx in 0 until destinationWidth) {
            val left = sx * factor
            val right = min(left + factor, sourceWidth)
            var sum = 0
            for (y in top until bottom) {
                val base = y * sourceWidth
                for (x in left until right) {
                    sum += source[base + x].toInt() and 0xFF
                }
            }
            destination[sy * destinationWidth + sx] = sum / ((bottom - top) * (right - left))
        }
    }
}

private fun boxRows(source: IntArray, destination: IntArray, width: Int, height: Int, radius: Int) {
    val window = 2 * radius + 1
    for (y in 0 until height) {
        val base = y * width
        var sum = 0
        for (dx in -radius..radius) {
            sum += source[base + dx.coerceIn(0, width - 1)]
        }
        for (x in 0 until width) {
            destination[base + x] = sum / window
            val add = (x + radius + 1).coerceAtMost(width - 1)
            val drop = (x - radius).coerceAtLeast(0)
            sum += source[base + add] - source[base + drop]
        }
    }
}

private fun boxColumns(
    source: IntArray,
    destination: IntArray,
    width: Int,
    height: Int,
    radius: Int,
) {
    val window = 2 * radius + 1
    for (x in 0 until width) {
        var sum = 0
        for (dy in -radius..radius) {
            sum += source[dy.coerceIn(0, height - 1) * width + x]
        }
        for (y in 0 until height) {
            destination[y * width + x] = sum / window
            val add = (y + radius + 1).coerceAtMost(height - 1)
            val drop = (y - radius).coerceAtLeast(0)
            sum += source[add * width + x] - source[drop * width + x]
        }
    }
}
