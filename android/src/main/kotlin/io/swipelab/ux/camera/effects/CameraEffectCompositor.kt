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
) : CameraCompositing {
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
    private var holdsFallback = true

    override fun composite(
        frame: CameraFrame,
        mask: CameraMask?,
    ): CompositeOutcome = synchronized(lock) {
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
        val active = try {
            adopt(frame.width, frame.height)
        } catch (_: Exception) {
            return substitution(frame, CameraCompositeSubstitution.RENDER_FAILED)
        }
        val output = active.pool?.take()
            ?: return substitution(frame, CameraCompositeSubstitution.POOL_UNAVAILABLE)
        val assessed = assess(mask, frame)
        val background = try {
            render(planes, assessed.mask, assessed.confidence, active.scratch, output)
        } catch (_: Exception) {
            output.release()
            return substitution(frame, CameraCompositeSubstitution.RENDER_FAILED)
        }
        // Publishing forks the claim before this one is given up, so the buffer
        // cannot recirculate while it is being handed out.
        val published = published(output, frame)
        if (holdsFallback) {
            lastGood?.release()
            lastGood = output
        } else {
            output.release()
        }
        CompositeOutcome.Composited(published, background, assessed.rejection)
    }

    /** Gives up the fallback claim; later composites keep none. */
    override fun retire() {
        synchronized(lock) {
            holdsFallback = false
            lastGood?.release()
            lastGood = null
            black?.release()
            black = null
        }
    }

    private fun adopt(width: Int, height: Int): Geometry {
        val current = geometry
        if (current != null && current.width == width && current.height == height) {
            return current
        }
        val replacement = Geometry(
            width,
            height,
            pools.makePool(width, height),
            RenderScratch(width, height, effect, dimNumerator),
        )
        geometry = replacement
        lastGood?.release()
        lastGood = null
        black?.release()
        black = null
        return replacement
    }

    private fun render(
        planes: CameraFramePlanes,
        mask: CameraMask?,
        confidence: FloatBuffer?,
        scratch: RenderScratch,
        output: CameraEffectBuffer,
    ): CameraBackgroundGrid {
        scratch.readInput(planes)
        if (mask != null) {
            scratch.prepareMask(mask, requireNotNull(confidence))
            scratch.composeOverPerson()
        } else {
            scratch.composeBackground()
        }
        scratch.writeInto(output)
        return scratch.backgroundGrid()
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
        val rejection = mask.rejectionOver(frame.width, frame.height)
        if (rejection != null) return AssessedMask(null, null, rejection)
        return AssessedMask(mask, mask.confidenceView(), null)
    }

    /** Fills the frame it was asked for, so a preserved other-sized fallback stays put. */
    private fun substitution(
        frame: CameraFrame,
        reason: CameraCompositeSubstitution,
    ): CompositeOutcome {
        val width = maxOf(1, frame.width)
        val height = maxOf(1, frame.height)
        if (!holdsFallback) {
            val substitute = makeBlackBuffer(width, height)
            val publication = published(substitute, frame)
            substitute.release()
            return CompositeOutcome.Substituted(
                publication, reason, CameraCompositeSubstitute.BLACK,
            )
        }
        val good = lastGood
        if (good != null && good.width == width && good.height == height) {
            return CompositeOutcome.Substituted(
                published(good, frame), reason, CameraCompositeSubstitute.LAST_GOOD,
            )
        }
        val current = black
        val substitute = if (current != null && current.width == width && current.height == height) {
            current
        } else {
            makeBlackBuffer(width, height).also {
                current?.release()
                black = it
            }
        }
        return CompositeOutcome.Substituted(
            published(substitute, frame), reason, CameraCompositeSubstitute.BLACK,
        )
    }

    /** Poolless, so a pool failure can always be answered. */
    private fun makeBlackBuffer(width: Int, height: Int): CameraEffectBuffer {
        val buffer = CameraEffectBuffer(null, width, height)
        buffer.fillBlack()
        return buffer
    }

    /**
     * The publication forks a claim on [buffer]; closing the published frame is
     * what gives that claim up.
     */
    private fun published(buffer: CameraEffectBuffer, from: CameraFrame): PublishedFrame {
        buffer.retain()
        return PublishedFrame(
            width = buffer.width,
            height = buffer.height,
            rotation = from.rotation,
            timestampNs = from.timestampNs,
            planes = CameraFramePlanes(
                width = buffer.width,
                height = buffer.height,
                dataY = buffer.publishedY(),
                strideY = buffer.width,
                dataU = buffer.publishedU(),
                strideU = buffer.chromaWidth,
                dataV = buffer.publishedV(),
                strideV = buffer.chromaWidth,
                onRelease = buffer::release,
            ),
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
private class RenderScratch(
    val width: Int,
    val height: Int,
    private val effect: CameraEffect,
    private val dimNumerator: Int,
) {
    val chromaWidth = (width + 1) / 2
    val chromaHeight = (height + 1) / 2

    /** 256 is the identity scale, so `NONE` is `DIM` without a reduction. */
    private val scale = if (effect == CameraEffect.DIM) dimNumerator else 256

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

    private var nearRow = IntArray(width)
    private var farRow = IntArray(width)
    private var nearIndex = -1

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

    private val columnEdges = IntArray(CameraBackgroundGrid.SIZE + 1)
    private val rowEdges = IntArray(CameraBackgroundGrid.SIZE + 1)
    private val cellPixels = IntArray(CameraBackgroundGrid.CELLS)
    private val backgroundSums = IntArray(CameraBackgroundGrid.CELLS)

    init {
        fillMapping(width, smallWidth, lumaIndex0, lumaIndex1, lumaFrac)
        fillMapping(chromaWidth, smallWidth, chromaIndex0, chromaIndex1, chromaFrac)
        for (index in 0..CameraBackgroundGrid.SIZE) {
            columnEdges[index] = CameraBackgroundGrid.edge(index, width)
            rowEdges[index] = CameraBackgroundGrid.edge(index, height)
        }
        for (row in 0 until CameraBackgroundGrid.SIZE) {
            val rows = rowEdges[row + 1] - rowEdges[row]
            for (column in 0 until CameraBackgroundGrid.SIZE) {
                cellPixels[row * CameraBackgroundGrid.SIZE + column] =
                    rows * (columnEdges[column + 1] - columnEdges[column])
            }
        }
    }

    fun readInput(planes: CameraFramePlanes) {
        copyPlane(planes.dataY, planes.strideY, width, height, inY)
        copyPlane(planes.dataU, planes.strideU, chromaWidth, chromaHeight, inU)
        copyPlane(planes.dataV, planes.strideV, chromaWidth, chromaHeight, inV)
    }

    fun composeBackground() {
        when (effect) {
            CameraEffect.NONE -> {
                System.arraycopy(inY, 0, outY, 0, inY.size)
                System.arraycopy(inU, 0, outU, 0, inU.size)
                System.arraycopy(inV, 0, outV, 0, inV.size)
            }

            CameraEffect.DIM -> {
                for (index in inY.indices) {
                    outY[index] = (((inY[index].toInt() and 0xFF) * scale) shr 8).toByte()
                }
                scaleChroma(inU, outU)
                scaleChroma(inV, outV)
            }

            CameraEffect.BLUR -> {
                blurLuma()
                blurChroma(inU, outU)
                blurChroma(inV, outV)
            }
        }
        measureAllBackground()
    }

    fun composeOverPerson() {
        backgroundSums.fill(0)
        val blurred = effect == CameraEffect.BLUR
        if (blurred) {
            blurLuma()
            blurChroma(inU, outU)
            blurChroma(inV, outV)
        }
        for (cellRow in 0 until CameraBackgroundGrid.SIZE) {
            val cellBase = cellRow * CameraBackgroundGrid.SIZE
            for (y in rowEdges[cellRow] until rowEdges[cellRow + 1]) {
                if (blurred) blurredLumaRow(y, cellBase) else scaledLumaRow(y, cellBase)
            }
        }
        for (y in 0 until chromaHeight) {
            if (blurred) blurredChromaRow(y) else scaledChromaRow(y)
        }
    }

    private fun scaleChroma(source: ByteArray, into: ByteArray) {
        for (index in source.indices) {
            val offset = (source[index].toInt() and 0xFF) - 128
            into[index] = (128 + ((offset * scale) shr 8)).toByte()
        }
    }

    private fun blurLuma() {
        blurPlane(
            inY, outY, width, height, LUMA_DOWNSCALE,
            lumaIndex0, lumaIndex1, lumaFrac,
        )
    }

    private fun blurChroma(source: ByteArray, into: ByteArray) {
        blurPlane(
            source, into, chromaWidth, chromaHeight, CHROMA_DOWNSCALE,
            chromaIndex0, chromaIndex1, chromaFrac,
        )
    }

    private fun blurPlane(
        source: ByteArray,
        into: ByteArray,
        planeWidth: Int,
        planeHeight: Int,
        factor: Int,
        index0: IntArray,
        index1: IntArray,
        frac: IntArray,
    ) {
        downscale(source, planeWidth, planeHeight, factor, smallA, smallWidth, smallHeight)
        for (radius in BOX_RADII) {
            boxRows(smallA, smallB, smallWidth, smallHeight, radius)
            boxColumns(smallB, smallA, smallWidth, smallHeight, radius)
        }
        nearIndex = -1
        for (y in 0 until planeHeight) {
            val gridRow = verticalMapping(2 * y + 1, smallHeight, 2 * planeHeight)
            holdGridRows(gridRow shr 9, planeWidth, index0, index1, frac)
            val weight = gridRow and 511
            val base = y * planeWidth
            for (x in 0 until planeWidth) {
                into[base + x] =
                    ((nearRow[x] * (256 - weight) + farRow[x] * weight + 128) shr 8).toByte()
            }
        }
    }

    /** A plane's rows walk the grid upwards, so each far row is the next near row. */
    private fun holdGridRows(
        index: Int,
        planeWidth: Int,
        index0: IntArray,
        index1: IntArray,
        frac: IntArray,
    ) {
        if (index == nearIndex) return
        if (nearIndex >= 0 && index == nearIndex + 1) {
            val carried = nearRow
            nearRow = farRow
            farRow = carried
        } else {
            stretchRow(smallA, index * smallWidth, nearRow, 0, index0, index1, frac, planeWidth)
        }
        stretchRow(
            smallA, min(index + 1, smallHeight - 1) * smallWidth,
            farRow, 0, index0, index1, frac, planeWidth,
        )
        nearIndex = index
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

    /** No person weight reaches the luma, so every pixel is background. */
    private fun measureAllBackground() {
        for (cell in backgroundSums.indices) backgroundSums[cell] = cellPixels[cell] shl 8
    }

    fun backgroundGrid(): CameraBackgroundGrid {
        val fractions = FloatArray(CameraBackgroundGrid.CELLS)
        for (cell in fractions.indices) {
            val pixels = cellPixels[cell]
            if (pixels > 0) fractions[cell] = backgroundSums[cell] / (pixels * 256f)
        }
        return CameraBackgroundGrid(fractions)
    }

    fun writeInto(output: CameraEffectBuffer) {
        output.write(outY, outU, outV)
    }

    private fun scaledLumaRow(y: Int, cellBase: Int) {
        val vertical = verticalMapping(2 * y + 1, maskGridHeight, 2 * height)
        val rowA = (vertical shr 9) * width
        val rowB = min((vertical shr 9) + 1, maskGridHeight - 1) * width
        val weight = vertical and 511
        val base = y * width
        for (cell in 0 until CameraBackgroundGrid.SIZE) {
            var backgroundWeight = 0
            for (x in columnEdges[cell] until columnEdges[cell + 1]) {
                val alpha =
                    (maskRows[rowA + x] * (256 - weight) + maskRows[rowB + x] * weight) shr 8
                outY[base + x] = scaledLumaOverPerson(inY[base + x], alpha)
                backgroundWeight += 256 - alpha
            }
            backgroundSums[cellBase + cell] += backgroundWeight
        }
    }

    private fun blurredLumaRow(y: Int, cellBase: Int) {
        val vertical = verticalMapping(2 * y + 1, maskGridHeight, 2 * height)
        val rowA = (vertical shr 9) * width
        val rowB = min((vertical shr 9) + 1, maskGridHeight - 1) * width
        val weight = vertical and 511
        val base = y * width
        for (cell in 0 until CameraBackgroundGrid.SIZE) {
            var backgroundWeight = 0
            for (x in columnEdges[cell] until columnEdges[cell + 1]) {
                val alpha =
                    (maskRows[rowA + x] * (256 - weight) + maskRows[rowB + x] * weight) shr 8
                outY[base + x] = stagedOverPerson(inY[base + x], outY[base + x], alpha)
                backgroundWeight += 256 - alpha
            }
            backgroundSums[cellBase + cell] += backgroundWeight
        }
    }

    /** Both chroma planes take the same alpha, so one walk carries them together. */
    private fun scaledChromaRow(y: Int) {
        val vertical = verticalMapping(4 * y + 2, maskGridHeight, 2 * height)
        val rowA = (vertical shr 9) * width
        val rowB = min((vertical shr 9) + 1, maskGridHeight - 1) * width
        val weight = vertical and 511
        val base = y * chromaWidth
        for (x in 0 until chromaWidth) {
            val column = min(2 * x, width - 1)
            val alpha =
                (maskRows[rowA + column] * (256 - weight) +
                    maskRows[rowB + column] * weight) shr 8
            outU[base + x] = scaledChromaOverPerson(inU[base + x], alpha)
            outV[base + x] = scaledChromaOverPerson(inV[base + x], alpha)
        }
    }

    /** Both chroma planes take the same alpha, so one walk carries them together. */
    private fun blurredChromaRow(y: Int) {
        val vertical = verticalMapping(4 * y + 2, maskGridHeight, 2 * height)
        val rowA = (vertical shr 9) * width
        val rowB = min((vertical shr 9) + 1, maskGridHeight - 1) * width
        val weight = vertical and 511
        val base = y * chromaWidth
        for (x in 0 until chromaWidth) {
            val column = min(2 * x, width - 1)
            val alpha =
                (maskRows[rowA + column] * (256 - weight) +
                    maskRows[rowB + column] * weight) shr 8
            outU[base + x] = stagedOverPerson(inU[base + x], outU[base + x], alpha)
            outV[base + x] = stagedOverPerson(inV[base + x], outV[base + x], alpha)
        }
    }

    private fun scaledLumaOverPerson(sample: Byte, alpha: Int): Byte {
        val person = sample.toInt() and 0xFF
        return blend(person, (person * scale) shr 8, alpha)
    }

    private fun scaledChromaOverPerson(sample: Byte, alpha: Int): Byte {
        val person = sample.toInt() and 0xFF
        return blend(person, 128 + (((person - 128) * scale) shr 8), alpha)
    }

    private fun stagedOverPerson(sample: Byte, background: Byte, alpha: Int): Byte =
        blend(sample.toInt() and 0xFF, background.toInt() and 0xFF, alpha)

    private fun blend(person: Int, background: Int, alpha: Int): Byte =
        ((person * alpha + background * (256 - alpha) + 128) shr 8).toByte()

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
