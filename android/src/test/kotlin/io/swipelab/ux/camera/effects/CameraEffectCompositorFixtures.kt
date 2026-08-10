package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer
import java.nio.FloatBuffer

class PlaneReadbackFailure : Exception()

/**
 * A frame over test-owned I420 planes. The row strides run wider than the
 * rows, and the declared size can differ from the planes' so a test can hand
 * the compositor a malformed frame.
 */
class EffectFrame(
    val width: Int,
    val height: Int,
    private val rotation: CameraFrameRotation = CameraFrameRotation.DEGREES_0,
    private val timestampNs: Long = 0,
    private val declaredWidth: Int = width,
    private val declaredHeight: Int = height,
    margin: Int = 3,
) {
    private val chromaWidth = (width + 1) / 2
    private val chromaHeight = (height + 1) / 2

    val strideY = width + margin
    val strideChroma = chromaWidth + margin

    val dataY: ByteBuffer = ByteBuffer.allocate(strideY * height)
    val dataU: ByteBuffer = ByteBuffer.allocate(strideChroma * chromaHeight)
    val dataV: ByteBuffer = ByteBuffer.allocate(strideChroma * chromaHeight)

    var releases = 0
        private set

    var failsToMaterialize = false

    init {
        fillLuma { _, _ -> 200 }
        fillChroma(128, 128)
    }

    fun fillLuma(value: (Int, Int) -> Int) {
        for (row in 0 until height) {
            for (column in 0 until width) {
                dataY.put(row * strideY + column, value(column, row).toByte())
            }
        }
    }

    fun fillChroma(u: Int, v: Int) {
        for (row in 0 until chromaHeight) {
            for (column in 0 until chromaWidth) {
                dataU.put(row * strideChroma + column, u.toByte())
                dataV.put(row * strideChroma + column, v.toByte())
            }
        }
    }

    fun frame(): CameraFrame = CameraFrame(
        width = declaredWidth,
        height = declaredHeight,
        rotation = rotation,
        timestampNs = timestampNs,
        source = {
            if (failsToMaterialize) throw PlaneReadbackFailure()
            CameraFramePlanes(
                width = width,
                height = height,
                dataY = dataY, strideY = strideY,
                dataU = dataU, strideU = strideChroma,
                dataV = dataV, strideV = strideChroma,
                onRelease = { releases += 1 },
            )
        },
    )
}

fun makeEffectMask(
    width: Int,
    height: Int,
    sourceRect: CameraFrameRect,
    person: CameraFrameRect? = null,
    declaredWidth: Int = width,
    declaredHeight: Int = height,
    sourceTimestampNs: Long = 0,
): CameraMask {
    val confidence = FloatBuffer.allocate(width * height)
    if (person != null) {
        for (row in person.y until person.y + person.height) {
            for (column in person.x until person.x + person.width) {
                confidence.put(row * width + column, 1f)
            }
        }
    }
    return CameraMask(
        confidence = confidence,
        width = declaredWidth,
        height = declaredHeight,
        sourceRect = sourceRect,
        sourceTimestampNs = sourceTimestampNs,
        generation = 0,
    )
}

fun luma(planes: CameraFramePlanes, x: Int, y: Int): Int =
    planes.dataY.get(y * planes.strideY + x).toInt() and 0xFF

fun chromaU(planes: CameraFramePlanes, x: Int, y: Int): Int =
    planes.dataU.get(y * planes.strideU + x).toInt() and 0xFF

fun chromaV(planes: CameraFramePlanes, x: Int, y: Int): Int =
    planes.dataV.get(y * planes.strideV + x).toInt() and 0xFF

class PoolCreationFailure : Exception()

/** Pools whose creation and allocations can be made to fail, over real pooled buffers. */
class ScriptedBufferPools(
    private val bound: Int = FrameBufferPool.ALLOCATION_BOUND,
) : CameraEffectBufferPools {
    var allocationsFail = false
    var creationFails = false

    inner class ScriptedPool(width: Int, height: Int) : CameraEffectBufferPool {
        private val delegate = FrameBufferPool(width, height, bound)

        val taken: Int get() = delegate.taken
        val exhausted: Int get() = delegate.exhausted
        val recycled: Int get() = delegate.recycled

        override fun take(): CameraEffectBuffer? =
            if (allocationsFail) null else delegate.take()
    }

    val pools = mutableListOf<ScriptedPool>()

    override fun makePool(width: Int, height: Int): CameraEffectBufferPool {
        if (creationFails) throw PoolCreationFailure()
        return ScriptedPool(width, height).also { pools.add(it) }
    }
}
