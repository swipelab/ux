package io.swipelab.ux.camera.effects

/**
 * One I420 output buffer, reference-counted: [release] at zero returns a
 * pooled buffer to its pool; a poolless buffer just stops circulating.
 */
class CameraEffectBuffer internal constructor(
    private val pool: FrameBufferPool?,
    val width: Int,
    val height: Int,
) {
    val chromaWidth = (width + 1) / 2
    val chromaHeight = (height + 1) / 2

    val dataY = ByteArray(width * height)
    val dataU = ByteArray(chromaWidth * chromaHeight)
    val dataV = ByteArray(chromaWidth * chromaHeight)

    private var references = 1

    fun retain(): Unit = synchronized(this) { references += 1 }

    fun release() {
        val recycles = synchronized(this) {
            references -= 1
            references == 0
        }
        if (recycles) pool?.recycle(this)
    }

    internal fun revive(): Unit = synchronized(this) { references = 1 }
}

/** Vends the compositor's output buffers for one geometry. */
interface CameraEffectBufferPool {
    /** `null` once the allocation bound is reached. */
    fun take(): CameraEffectBuffer?
}

/**
 * Fixed-geometry I420 buffers under a fixed allocation bound; a released
 * buffer recirculates through [take].
 */
class FrameBufferPool(
    val width: Int,
    val height: Int,
    private val bound: Int = ALLOCATION_BOUND,
) : CameraEffectBufferPool {
    companion object {
        /** One last-good slot plus the frames in flight downstream. */
        const val ALLOCATION_BOUND = 8
    }

    private val free = ArrayDeque<CameraEffectBuffer>()
    private var allocated = 0
    private var takenCount = 0
    private var exhaustedCount = 0

    val taken: Int get() = synchronized(this) { takenCount }

    val exhausted: Int get() = synchronized(this) { exhaustedCount }

    override fun take(): CameraEffectBuffer? = synchronized(this) {
        val buffer = free.removeFirstOrNull()
            ?: if (allocated < bound) {
                allocated += 1
                CameraEffectBuffer(this, width, height)
            } else {
                null
            }
        if (buffer == null) {
            exhaustedCount += 1
        } else {
            takenCount += 1
            buffer.revive()
        }
        buffer
    }

    internal fun recycle(buffer: CameraEffectBuffer) = synchronized(this) {
        free.addLast(buffer)
    }
}

/** Stands up the pool for an output geometry; `null` refuses the geometry. */
interface CameraEffectBufferPools {
    fun makePool(width: Int, height: Int): CameraEffectBufferPool?
}

class FrameBufferPools(
    private val bound: Int = FrameBufferPool.ALLOCATION_BOUND,
) : CameraEffectBufferPools {
    override fun makePool(width: Int, height: Int): CameraEffectBufferPool? =
        FrameBufferPool(width, height, bound)
}
