package io.swipelab.ux.camera.effects

import kotlin.math.ceil
import org.junit.Assert.assertTrue
import org.junit.Test

private const val WIDTH = 1280
private const val HEIGHT = 720
private const val WARMUP = 40
private const val SAMPLES = 300

/** A composite leaves room beside inference inside a 33 ms frame at 30fps. */
private const val MEAN_BUDGET_MS = 12.0
private const val P99_BUDGET_MS = 24.0

/**
 * Composite latency over 720p I420 frames and a 256x144 mask, one scene per
 * effect and mask state.
 *
 * The blur's look matches the macOS graph's full-resolution Gaussian radius of
 * 18 by summing variances: the 8x box decimation contributes sigma 2.3, the
 * three box passes on the 1/8 grid sigma 17.3, and the bilinear upscale sigma
 * 3.3, for sigma 17.8 full-resolution pixels.
 */
class CameraEffectCompositorBenchmark {
    private fun measure(effect: CameraEffect, mask: CameraMask?, label: String) {
        val compositor = CameraEffectCompositor(effect)
        val frames = (0 until 4).map { index ->
            EffectFrame(width = WIDTH, height = HEIGHT).apply {
                fillLuma { x, y -> (x + y + index * 37) % 256 }
            }
        }
        val samples = DoubleArray(SAMPLES)
        for (index in 0 until WARMUP + SAMPLES) {
            val input = frames[index % frames.size].frame()
            val start = System.nanoTime()
            val outcome = compositor.composite(input, mask)
            val elapsed = (System.nanoTime() - start) / 1_000_000.0
            assertTrue("$label substituted: $outcome", outcome is CompositeOutcome.Composited)
            outcome.frame.close()
            if (index >= WARMUP) samples[index - WARMUP] = elapsed
        }

        val mean = samples.average()
        samples.sort()
        val p99 = samples[ceil(SAMPLES * 0.99).toInt() - 1]
        println(
            "compositor benchmark %s: mean %.3f ms, p99 %.3f ms over %d composites at %dx%d"
                .format(label, mean, p99, SAMPLES, WIDTH, HEIGHT)
        )
        assertTrue("$label mean $mean ms over $MEAN_BUDGET_MS ms", mean <= MEAN_BUDGET_MS)
        assertTrue("$label p99 $p99 ms over $P99_BUDGET_MS ms", p99 <= P99_BUDGET_MS)
    }

    private fun personMask(): CameraMask = makeEffectMask(
        width = 256,
        height = 144,
        sourceRect = CameraFrameRect(0, 0, WIDTH, HEIGHT),
        person = CameraFrameRect(64, 36, 128, 72),
    )

    @Test
    fun blurWithAMaskLatency() = measure(CameraEffect.BLUR, personMask(), "blur masked")

    @Test
    fun blurWithoutAMaskLatency() = measure(CameraEffect.BLUR, null, "blur unmasked")

    @Test
    fun dimWithAMaskLatency() = measure(CameraEffect.DIM, personMask(), "dim masked")

    @Test
    fun dimWithoutAMaskLatency() = measure(CameraEffect.DIM, null, "dim unmasked")
}
