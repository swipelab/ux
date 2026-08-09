package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import java.util.zip.CRC32
import org.junit.Assert.assertEquals
import org.junit.Test

/** One digest per scene over the composite's Y, U and V bytes. */
private const val PINNED = """
blur masked = 1934328522
dim masked = 1077197661
none masked = 952301543
blur unmasked = 3680017666
dim unmasked = 3004196487
blur odd size = 3543320422
dim odd size = 1848893675
dim quarter turn = 1169247778
"""

class CameraEffectCompositorOutputTest {
    private class Scene(
        val label: String,
        val effect: CameraEffect,
        val width: Int,
        val height: Int,
        val rotation: CameraFrameRotation = CameraFrameRotation.DEGREES_0,
        val mask: (Int, Int) -> CameraMask?,
    )

    private fun personMask(width: Int, height: Int): CameraMask = makeEffectMask(
        width = 40,
        height = 24,
        sourceRect = CameraFrameRect(0, 0, width, height),
        person = CameraFrameRect(11, 6, 17, 11),
    )

    private fun quarterTurnMask(width: Int, height: Int): CameraMask {
        val upright = PersonMaskPixels(
            width = 24,
            height = 40,
            confidence = FloatBuffer.allocate(24 * 40).apply {
                for (row in 6 until 22) {
                    for (column in 5 until 19) put(row * 24 + column, 1f)
                }
            },
        ).onInputGrid(CameraFrameRotation.DEGREES_90)
        return CameraMask(
            confidence = upright.confidence,
            width = upright.width,
            height = upright.height,
            sourceRect = CameraFrameRect(0, 0, width, height),
            sourceTimestampNs = 0,
            generation = 0,
        )
    }

    private val scenes = listOf(
        Scene("blur masked", CameraEffect.BLUR, 320, 180, mask = ::personMask),
        Scene("dim masked", CameraEffect.DIM, 320, 180, mask = ::personMask),
        Scene("none masked", CameraEffect.NONE, 320, 180, mask = ::personMask),
        Scene("blur unmasked", CameraEffect.BLUR, 320, 180, mask = { _, _ -> null }),
        Scene("dim unmasked", CameraEffect.DIM, 320, 180, mask = { _, _ -> null }),
        Scene("blur odd size", CameraEffect.BLUR, 37, 23, mask = ::personMask),
        Scene("dim odd size", CameraEffect.DIM, 37, 23, mask = ::personMask),
        Scene(
            "dim quarter turn",
            CameraEffect.DIM,
            320,
            180,
            CameraFrameRotation.DEGREES_90,
            ::quarterTurnMask,
        ),
    )

    private fun digest(planes: CameraFramePlanes): Long {
        val crc = CRC32()
        for (y in 0 until planes.height) {
            for (x in 0 until planes.width) crc.update(luma(planes, x, y))
        }
        for (y in 0 until (planes.height + 1) / 2) {
            for (x in 0 until (planes.width + 1) / 2) {
                crc.update(chromaU(planes, x, y))
                crc.update(chromaV(planes, x, y))
            }
        }
        return crc.value
    }

    private fun render(scene: Scene): Long {
        val compositor = CameraEffectCompositor(scene.effect)
        val input = EffectFrame(
            width = scene.width,
            height = scene.height,
            rotation = scene.rotation,
        ).apply {
            fillLuma { x, y -> (x * 7 + y * 13) % 256 }
            fillChroma(90, 200)
        }
        val outcome = compositor.composite(input.frame(), scene.mask(scene.width, scene.height))
        val value = digest(outcome.frame.planes)
        outcome.frame.close()
        compositor.retire()
        return value
    }

    @Test
    fun everySceneRendersToItsPinnedBytes() {
        val rendered = scenes.joinToString("\n") { "${it.label} = ${render(it)}" }

        assertEquals(PINNED.trim(), rendered)
    }
}
