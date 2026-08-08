package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import org.junit.Assert.assertThrows
import org.junit.Test

class CameraMaskTest {
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
}
