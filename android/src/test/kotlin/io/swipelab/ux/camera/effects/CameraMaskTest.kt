package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class CameraMaskTest {
    private fun uprightMask(): PersonMaskPixels {
        return PersonMaskPixels(
            width = 4,
            height = 6,
            confidence = FloatBuffer.wrap(FloatArray(24) { (it + 1) / 100f }),
        )
    }

    private fun assertGrid(
        pixels: PersonMaskPixels,
        width: Int,
        height: Int,
        vararg expected: Int,
    ) {
        assertEquals(width, pixels.width)
        assertEquals(height, pixels.height)
        val actual = FloatArray(width * height)
        pixels.confidence.get(actual)
        assertArrayEquals(expected.map { it / 100f }.toFloatArray(), actual, 0f)
    }

    @Test
    fun anUnturnedMaskKeepsItsGridAndItsCells() {
        val mapped = uprightMask().onInputGrid(CameraFrameRotation.DEGREES_0)

        assertGrid(
            mapped, 4, 6,
            1, 2, 3, 4,
            5, 6, 7, 8,
            9, 10, 11, 12,
            13, 14, 15, 16,
            17, 18, 19, 20,
            21, 22, 23, 24,
        )
    }

    @Test
    fun aQuarterTurnedMaskMapsBackOntoTheInputGrid() {
        val mapped = uprightMask().onInputGrid(CameraFrameRotation.DEGREES_90)

        assertGrid(
            mapped, 6, 4,
            4, 8, 12, 16, 20, 24,
            3, 7, 11, 15, 19, 23,
            2, 6, 10, 14, 18, 22,
            1, 5, 9, 13, 17, 21,
        )
    }

    @Test
    fun aThreeQuarterTurnedMaskMapsBackOntoTheInputGrid() {
        val mapped = uprightMask().onInputGrid(CameraFrameRotation.DEGREES_270)

        assertGrid(
            mapped, 6, 4,
            21, 17, 13, 9, 5, 1,
            22, 18, 14, 10, 6, 2,
            23, 19, 15, 11, 7, 3,
            24, 20, 16, 12, 8, 4,
        )
    }

    @Test
    fun aHalfTurnedMaskMapsBackOntoTheInputGrid() {
        val mapped = uprightMask().onInputGrid(CameraFrameRotation.DEGREES_180)

        assertGrid(
            mapped, 4, 6,
            24, 23, 22, 21,
            20, 19, 18, 17,
            16, 15, 14, 13,
            12, 11, 10, 9,
            8, 7, 6, 5,
            4, 3, 2, 1,
        )
    }

    @Test
    fun personMaskPixelsRejectsAnUndersizedBuffer() {
        assertThrows(IllegalArgumentException::class.java) {
            PersonMaskPixels(16, 12, FloatBuffer.allocate(16 * 12 - 1))
        }
    }

    @Test
    fun personMaskPixelsRejectsALimitShortenedBuffer() {
        val confidence = FloatBuffer.allocate(16 * 12).apply { limit(16 * 12 - 1) }

        assertThrows(IllegalArgumentException::class.java) {
            PersonMaskPixels(16, 12, confidence)
        }
    }

    @Test
    fun personMaskPixelsRejectsAnOverflowingGrid() {
        assertThrows(IllegalArgumentException::class.java) {
            PersonMaskPixels(Int.MAX_VALUE, 2, FloatBuffer.allocate(1))
        }
    }

    @Test
    fun aMaskOverItsOwnFrameWithAPersonIsNotRejected() {
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            person = CameraFrameRect(8, 6, 16, 12),
        )

        assertNull(mask.rejectionOver(64, 36))
    }

    @Test
    fun aMaskDeclaringNoGridIsRejectedAsZeroDimensioned() {
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            person = CameraFrameRect(8, 6, 16, 12),
            declaredWidth = 0,
            declaredHeight = 0,
        )

        assertEquals(CameraMaskRejection.ZERO_DIMENSIONED, mask.rejectionOver(64, 36))
    }

    @Test
    fun aMaskTakenOverAnotherRegionIsRejectedAsSourceRectMismatch() {
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(10, 0, 64, 36),
            person = CameraFrameRect(8, 6, 16, 12),
        )

        assertEquals(CameraMaskRejection.SOURCE_RECT_MISMATCH, mask.rejectionOver(64, 36))
    }

    @Test
    fun aMaskOverAFrameOfAnotherSizeIsRejectedAsSourceRectMismatch() {
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            person = CameraFrameRect(8, 6, 16, 12),
        )

        assertEquals(CameraMaskRejection.SOURCE_RECT_MISMATCH, mask.rejectionOver(320, 180))
    }

    @Test
    fun aMaskShorterThanItsGridIsRejectedAsInvalidStorage() {
        val mask = CameraMask(
            confidence = FloatBuffer.allocate(32 * 24 - 1),
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            generation = 0,
        )

        assertEquals(CameraMaskRejection.INVALID_STORAGE, mask.rejectionOver(64, 36))
    }

    @Test
    fun aMaskWhoseGridOverflowsIsRejectedAsInvalidStorage() {
        val mask = CameraMask(
            confidence = FloatBuffer.allocate(1),
            width = Int.MAX_VALUE,
            height = 2,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            generation = 0,
        )

        assertEquals(CameraMaskRejection.INVALID_STORAGE, mask.rejectionOver(64, 36))
    }

    @Test
    fun aMaskWithNoPersonAnywhereIsRejectedAsEmpty() {
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
        )

        assertEquals(CameraMaskRejection.EMPTY, mask.rejectionOver(64, 36))
    }
}
