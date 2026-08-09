package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private const val SIZE = CameraBackgroundGrid.SIZE

/** One destination sample's two source indices and its 0..256 weight. */
private class Tap(size: Int, position: Double) {
    val index0: Int
    val index1: Int
    val weight: Int

    init {
        var index = floor(position).toInt()
        var mix = ((position - index) * 256).roundToInt()
        if (index < 0) {
            index = 0
            mix = 0
        }
        if (index >= size - 1) {
            index = size - 1
            mix = 0
        }
        index0 = index
        index1 = min(index + 1, size - 1)
        weight = mix
    }
}

/**
 * The alpha the blend applies at each luma pixel: the mask's rows stretched
 * across the frame's width, then interpolated between rows down its height.
 */
private fun appliedAlpha(mask: CameraMask, width: Int, height: Int): IntArray {
    val confidence = mask.confidence
    val stretched = IntArray(mask.height * width)
    for (x in 0 until width) {
        val tap = Tap(mask.width, (x + 0.5) * mask.width / width - 0.5)
        for (row in 0 until mask.height) {
            val base = row * mask.width
            stretched[row * width + x] = (
                confidence.get(base + tap.index0) * (256 - tap.weight) +
                    confidence.get(base + tap.index1) * tap.weight + 0.5f
                ).toInt()
        }
    }
    val alpha = IntArray(width * height)
    for (y in 0 until height) {
        val tap = Tap(mask.height, (2.0 * y + 1) * mask.height / (2.0 * height) - 0.5)
        val rowA = tap.index0 * width
        val rowB = tap.index1 * width
        for (x in 0 until width) {
            alpha[y * width + x] = (
                stretched[rowA + x] * (256 - tap.weight) + stretched[rowB + x] * tap.weight
                ) shr 8
        }
    }
    return alpha
}

private fun meanBackground(alpha: IntArray, width: Int, height: Int): FloatArray {
    val fractions = FloatArray(CameraBackgroundGrid.CELLS)
    for (row in 0 until SIZE) {
        for (column in 0 until SIZE) {
            var sum = 0L
            var pixels = 0
            for (y in CameraBackgroundGrid.edge(row, height)
                until CameraBackgroundGrid.edge(row + 1, height)) {
                for (x in CameraBackgroundGrid.edge(column, width)
                    until CameraBackgroundGrid.edge(column + 1, width)) {
                    sum += 256 - alpha[y * width + x]
                    pixels += 1
                }
            }
            if (pixels > 0) fractions[row * SIZE + column] = sum / (pixels * 256f)
        }
    }
    return fractions
}

private fun cells(grid: CameraBackgroundGrid): FloatArray =
    FloatArray(CameraBackgroundGrid.CELLS) { grid.fraction(it % SIZE, it / SIZE) }

class CameraBackgroundGridTest {
    private fun composited(outcome: CompositeOutcome): CompositeOutcome.Composited {
        assertTrue("expected a composite, got $outcome", outcome is CompositeOutcome.Composited)
        return outcome as CompositeOutcome.Composited
    }

    private fun grid(
        effect: CameraEffect,
        width: Int,
        height: Int,
        mask: CameraMask?,
        rotation: CameraFrameRotation = CameraFrameRotation.DEGREES_0,
        rejection: CameraMaskRejection? = null,
    ): CameraBackgroundGrid {
        val compositor = CameraEffectCompositor(effect)
        val input = EffectFrame(width = width, height = height, rotation = rotation).apply {
            fillLuma { x, y -> (x * 7 + y * 13) % 256 }
        }
        val outcome = composited(compositor.composite(input.frame(), mask))
        assertEquals(rejection, outcome.maskRejection)
        outcome.frame.close()
        compositor.retire()
        return outcome.background
    }

    @Test
    fun aSplitMasksCellsHoldTheMeanBackgroundWeightOfTheirPixels() {
        val mask = makeEffectMask(
            width = 40,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 320, 180),
            person = CameraFrameRect(11, 6, 17, 11),
        )

        val measured = grid(CameraEffect.DIM, 320, 180, mask)

        assertArrayEquals(
            meanBackground(appliedAlpha(mask, 320, 180), 320, 180),
            cells(measured),
            0f,
        )
    }

    @Test
    fun aMaskOverEveryPixelLeavesNoBackgroundInAnyCell() {
        val mask = makeEffectMask(
            width = 40,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 320, 180),
            person = CameraFrameRect(0, 0, 40, 24),
        )

        val measured = grid(CameraEffect.BLUR, 320, 180, mask)

        assertArrayEquals(FloatArray(CameraBackgroundGrid.CELLS), cells(measured), 0f)
    }

    @Test
    fun aMaskCoveringNothingIsSetAsideAndEveryCellIsWhollyBackground() {
        val mask = makeEffectMask(
            width = 40,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 320, 180),
        )

        val measured = grid(CameraEffect.DIM, 320, 180, mask, rejection = CameraMaskRejection.EMPTY)

        assertArrayEquals(FloatArray(CameraBackgroundGrid.CELLS) { 1f }, cells(measured), 0f)
    }

    @Test
    fun withoutAMaskEveryCellIsWhollyBackground() {
        val measured = grid(CameraEffect.BLUR, 320, 180, null)

        assertArrayEquals(FloatArray(CameraBackgroundGrid.CELLS) { 1f }, cells(measured), 0f)
    }

    @Test
    fun aQuarterTurnMasksCellsHoldTheMeanBackgroundWeightOfTheirPixels() {
        val upright = PersonMaskPixels(
            width = 24,
            height = 40,
            confidence = FloatBuffer.allocate(24 * 40).apply {
                for (row in 6 until 22) {
                    for (column in 5 until 19) put(row * 24 + column, 1f)
                }
            },
        ).onInputGrid(CameraFrameRotation.DEGREES_90)
        val mask = CameraMask(
            confidence = upright.confidence,
            width = upright.width,
            height = upright.height,
            sourceRect = CameraFrameRect(0, 0, 320, 180),
            generation = 0,
        )

        val measured = grid(
            CameraEffect.DIM, 320, 180, mask, rotation = CameraFrameRotation.DEGREES_90,
        )

        assertArrayEquals(
            meanBackground(appliedAlpha(mask, 320, 180), 320, 180),
            cells(measured),
            0f,
        )
    }

    @Test
    fun aFrameNoMultipleOfTheGridSplitsItsPixelsIntoWholeCells() {
        val edges = IntArray(SIZE + 1) { CameraBackgroundGrid.edge(it, 37) }

        assertArrayEquals(
            intArrayOf(0, 2, 4, 6, 9, 11, 13, 16, 18, 20, 23, 25, 27, 30, 32, 34, 37),
            edges,
        )
    }

    @Test
    fun aFrameNoMultipleOfTheGridHoldsTheMeanBackgroundWeightOfEachCellsPixels() {
        val mask = makeEffectMask(
            width = 11,
            height = 7,
            sourceRect = CameraFrameRect(0, 0, 37, 23),
            person = CameraFrameRect(3, 2, 5, 3),
        )

        val measured = grid(CameraEffect.DIM, 37, 23, mask)

        assertArrayEquals(
            meanBackground(appliedAlpha(mask, 37, 23), 37, 23),
            cells(measured),
            0f,
        )
    }

    @Test
    fun theGridFollowsTheInterpolatedAlphaAndNotTheRawMaskSamples() {
        val maskWidth = 4
        val maskHeight = 4
        val mask = makeEffectMask(
            width = maskWidth,
            height = maskHeight,
            sourceRect = CameraFrameRect(0, 0, 320, 180),
            person = CameraFrameRect(1, 1, 1, 1),
        )
        val raw = FloatArray(CameraBackgroundGrid.CELLS) { cell ->
            val column = CameraBackgroundGrid.edge(cell % SIZE, maskWidth)
            val row = CameraBackgroundGrid.edge(cell / SIZE, maskHeight)
            1f - mask.confidence.get(row * maskWidth + column)
        }

        val measured = grid(CameraEffect.DIM, 320, 180, mask)

        val cells = cells(measured)
        assertArrayEquals(
            meanBackground(appliedAlpha(mask, 320, 180), 320, 180),
            cells,
            0f,
        )
        val widest = cells.indices.maxOf { abs(cells[it] - raw[it]) }
        assertTrue("raw samples should not stand in for the blend, got $widest", widest > 0.2f)
    }

    /**
     * Dimming a 255 frame leaves person 255 over background 127, so each output
     * luma pins its pixel's alpha to within one rounding step and a cell's
     * emitted sum brackets the fraction the grid reports.
     */
    @Test
    fun everyCellsFractionMatchesTheLumaTheCompositeEmitted() {
        val width = 320
        val height = 180
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = width, height = height).apply {
            fillLuma { _, _ -> 255 }
        }
        val mask = makeEffectMask(
            width = 40,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, width, height),
            person = CameraFrameRect(11, 6, 17, 11),
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        val planes = outcome.frame.planes
        for (row in 0 until SIZE) {
            for (column in 0 until SIZE) {
                var sum = 0L
                var pixels = 0
                for (y in CameraBackgroundGrid.edge(row, height)
                    until CameraBackgroundGrid.edge(row + 1, height)) {
                    for (x in CameraBackgroundGrid.edge(column, width)
                        until CameraBackgroundGrid.edge(column + 1, width)) {
                        sum += luma(planes, x, y)
                        pixels += 1
                    }
                }
                val leastAlpha = (256.0 * sum - pixels * 32640.0) / 128.0
                val mostAlpha = leastAlpha + 255.0 * pixels / 128.0
                val fraction = outcome.background.fraction(column, row)
                val floor = 1.0 - mostAlpha / (256.0 * pixels)
                val ceiling = 1.0 - leastAlpha / (256.0 * pixels)
                assertTrue(
                    "cell ($column,$row) reports $fraction, output implies $floor..$ceiling",
                    fraction >= floor - 1e-6 && fraction <= ceiling + 1e-6,
                )
            }
        }
        outcome.frame.close()
    }
}
