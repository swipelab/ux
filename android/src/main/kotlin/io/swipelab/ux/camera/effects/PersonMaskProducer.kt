package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * The mode a segmenter runs in. Each answers on its own grid, whose aspect
 * does not track the input's.
 */
enum class PersonMaskQuality {
    STREAM,
    SINGLE_IMAGE,
}

/** One inference input: NV21 pixels the producer owns, on a fixed grid. */
class PersonMaskInput(val width: Int, val height: Int) {
    private val chromaWidth = (width + 1) / 2
    private val chromaHeight = (height + 1) / 2

    val nv21: ByteBuffer =
        ByteBuffer.allocateDirect(width * height + 2 * chromaWidth * chromaHeight)
}

/**
 * The producer's inference inputs: a fixed set of buffers, one per holder that
 * can be outstanding at once. [take] answers `null` once they are all out, and
 * a buffer returns through [recycle] when the inference it was lent to ends.
 */
class PersonMaskInputPool(width: Int, height: Int, capacity: Int) {
    private val free = ArrayDeque<PersonMaskInput>().apply {
        repeat(capacity) { add(PersonMaskInput(width, height)) }
    }

    private var takenCount = 0
    private var exhaustedCount = 0

    val taken: Int get() = synchronized(this) { takenCount }

    val exhausted: Int get() = synchronized(this) { exhaustedCount }

    fun take(): PersonMaskInput? = synchronized(this) {
        val input = free.removeFirstOrNull()
        if (input == null) exhaustedCount += 1 else takenCount += 1
        input
    }

    fun recycle(input: PersonMaskInput) = synchronized(this) {
        free.addLast(input)
    }
}

/**
 * Person segmentation over one ux-owned input, answering through the
 * completion when the inference finishes.
 */
interface PersonSegmenting : AutoCloseable {
    val quality: PersonMaskQuality

    /** Called on the producer's executor, one submission at a time. */
    fun submit(input: PersonMaskInput, completion: (Result<PersonMaskPixels>) -> Unit)

    override fun close() = Unit
}

interface PersonMaskExecutor : Executor, AutoCloseable

private class SerialPersonMaskExecutor : PersonMaskExecutor {
    private val delegate = Executors.newSingleThreadExecutor { body ->
        Thread(body, "ux-person-mask")
    }

    override fun execute(command: Runnable) = delegate.execute(command)

    override fun close() {
        delegate.shutdownNow()
    }
}

/**
 * Keeps one person mask current for the compositor to pull: an eligible
 * frame's pixels are downscaled into a ux-owned input and handed to one serial
 * executor, and the newest generation-matched result is published.
 */
class PersonMaskProducer(
    private val segmenter: PersonSegmenting,
    private val pool: PersonMaskInputPool = PersonMaskInputPool(
        INPUT_WIDTH, INPUT_HEIGHT, INPUT_BUFFER_COUNT,
    ),
    private val clock: CameraEffectsClock = MonotonicClock(),
    private val executor: PersonMaskExecutor = SerialPersonMaskExecutor(),
) : AutoCloseable {
    companion object {
        /** The inference input's size, in the frame's unrotated pixel space. */
        const val INPUT_WIDTH = 256
        const val INPUT_HEIGHT = 144

        /**
         * One buffer for the inference in flight, one for work [reset]
         * abandoned while it is still held.
         */
        const val INPUT_BUFFER_COUNT = 2

        const val TARGET_SUBMISSIONS_PER_SECOND = 15
        const val TARGET_SUBMISSION_INTERVAL_NANOS =
            1_000_000_000L / TARGET_SUBMISSIONS_PER_SECOND
    }

    private val lock = Any()

    private var closed = false
    private var published: CameraMask? = null
    private var inFlight = false
    private var generation = 0
    private var lastSubmissionAt: Long? = null
    private var interval = TARGET_SUBMISSION_INTERVAL_NANOS
    private var publications = 0

    val mask: CameraMask? get() = synchronized(lock) { published }

    val submissionIntervalNanos: Long get() = synchronized(lock) { interval }

    /**
     * Takes what this frame owes the next mask and returns; it never waits on
     * an inference and never retains the frame's planes.
     */
    fun consider(frame: CameraFrame) {
        val claimed = claim() ?: return
        val input = pool.take() ?: return release(claimed)
        var enqueued = false
        try {
            val planes = frame.planes()
            if (planes.width <= 0 || planes.height <= 0) return
            copy(planes, input)
            val sourceRect = CameraFrameRect(0, 0, planes.width, planes.height)
            val submission = stamp(sourceRect, claimed, input) ?: return
            enqueued = enqueue(submission)
        } catch (_: Exception) {
        } finally {
            if (!enqueued) {
                pool.recycle(input)
                release(claimed)
            }
        }
    }

    /**
     * Retires every mask and submission of the effect that ends here. Work
     * still inside the segmenter is abandoned rather than waited on.
     */
    fun reset() = synchronized(lock) {
        if (closed) return@synchronized
        generation += 1
        published = null
        inFlight = false
        lastSubmissionAt = null
        interval = TARGET_SUBMISSION_INTERVAL_NANOS
    }

    override fun close() {
        val closesResources = synchronized(lock) {
            if (closed) return@synchronized false
            closed = true
            generation += 1
            published = null
            inFlight = false
            lastSubmissionAt = null
            interval = TARGET_SUBMISSION_INTERVAL_NANOS
            true
        }
        if (!closesResources) return
        try {
            segmenter.close()
        } finally {
            executor.close()
        }
    }

    private class Submission(
        val generation: Int,
        val sourceRect: CameraFrameRect,
        val input: PersonMaskInput,
        val submittedAt: Long,
    )

    /**
     * The generation the caller may submit under, or `null` when an inference
     * is in flight or the cadence gate has not opened.
     */
    private fun claim(): Int? = synchronized(lock) {
        if (closed) return null
        if (inFlight) return null
        val last = lastSubmissionAt
        if (last != null && clock.nowNanos - last < interval) return null
        inFlight = true
        generation
    }

    private fun release(claimed: Int) = synchronized(lock) {
        if (claimed == generation) inFlight = false
    }

    private fun stamp(
        sourceRect: CameraFrameRect,
        claimed: Int,
        input: PersonMaskInput,
    ): Submission? = synchronized(lock) {
        if (closed || claimed != generation) return null
        Submission(claimed, sourceRect, input, clock.nowNanos)
    }

    private fun enqueue(submission: Submission): Boolean = synchronized(lock) {
        if (closed || submission.generation != generation) {
            false
        } else {
            executor.execute { submit(submission) }
            lastSubmissionAt = submission.submittedAt
            true
        }
    }

    private fun submit(submission: Submission) {
        val active = synchronized(lock) { !closed }
        if (!active) {
            pool.recycle(submission.input)
            return
        }
        segmenter.submit(submission.input) { result -> complete(result, submission) }
    }

    private fun complete(result: Result<PersonMaskPixels>, submission: Submission) {
        pool.recycle(submission.input)
        synchronized(lock) {
            if (closed || submission.generation != generation) return
            inFlight = false
            val pixels = result.getOrNull() ?: return
            published = CameraMask(
                confidence = pixels.confidence,
                width = pixels.width,
                height = pixels.height,
                sourceRect = submission.sourceRect,
                generation = submission.generation,
            )
            publications += 1
            // The first inference of a producer carries the model load, which
            // is two orders of magnitude slower than a warm one.
            if (publications <= 1) return
            interval = maxOf(
                TARGET_SUBMISSION_INTERVAL_NANOS, clock.nowNanos - submission.submittedAt,
            )
        }
    }

    /**
     * Downscales the frame's I420 planes into the input's NV21 grid. Copying
     * is what lets the camera's planes go back with the frame callback that
     * lent them.
     */
    private fun copy(planes: CameraFramePlanes, input: PersonMaskInput) {
        val destination = input.nv21
        for (row in 0 until input.height) {
            val sourceBase = (row * planes.height / input.height) * planes.strideY
            val destinationBase = row * input.width
            for (column in 0 until input.width) {
                destination.put(
                    destinationBase + column,
                    planes.dataY.get(sourceBase + column * planes.width / input.width),
                )
            }
        }

        val sourceChromaWidth = (planes.width + 1) / 2
        val sourceChromaHeight = (planes.height + 1) / 2
        val chromaWidth = (input.width + 1) / 2
        val chromaHeight = (input.height + 1) / 2
        val chromaBase = input.width * input.height
        for (row in 0 until chromaHeight) {
            val sourceRow = row * sourceChromaHeight / chromaHeight
            val destinationBase = chromaBase + row * chromaWidth * 2
            for (column in 0 until chromaWidth) {
                val sourceColumn = column * sourceChromaWidth / chromaWidth
                destination.put(
                    destinationBase + column * 2,
                    planes.dataV.get(sourceRow * planes.strideV + sourceColumn),
                )
                destination.put(
                    destinationBase + column * 2 + 1,
                    planes.dataU.get(sourceRow * planes.strideU + sourceColumn),
                )
            }
        }
    }
}
