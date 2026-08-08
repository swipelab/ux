package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer
import java.nio.FloatBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class ScriptedSegmenterFailure : Exception()

class TestClock : CameraEffectsClock {
    private var value = 0L

    override val nowNanos: Long get() = synchronized(this) { value }

    fun advance(nanos: Long) = synchronized(this) { value += nanos }
}

fun makeMaskPixels(width: Int = 256, height: Int = 144): PersonMaskPixels =
    PersonMaskPixels(width, height, FloatBuffer.allocate(width * height))

/** Holds what it is handed until the test runs it, on the test's own thread. */
class ManualExecutor : PersonMaskExecutor {
    private val pending = ArrayDeque<Runnable>()
    var closes = 0
        private set

    override fun execute(command: Runnable) {
        pending.add(command)
    }

    fun runNext(): Boolean = pending.removeFirstOrNull()?.let { it.run(); true } ?: false

    override fun close() {
        closes += 1
        pending.clear()
    }
}

class TestPersonMaskExecutor : PersonMaskExecutor {
    @Volatile
    private var worker: Thread? = null
    private val delegate = Executors.newSingleThreadExecutor { body ->
        Thread(body, "ux-person-mask-test").also { worker = it }
    }

    var closes = 0
        private set

    override fun execute(command: Runnable) = delegate.execute(command)

    fun drain() {
        delegate.submit {}.get()
    }

    fun workerStopsWithin(timeoutMillis: Long): Boolean {
        val current = worker ?: return true
        current.join(timeoutMillis)
        return !current.isAlive
    }

    override fun close() {
        closes += 1
        delegate.shutdownNow()
    }
}

/** A frame over test-owned I420 planes the test can rewrite or count. */
class TestFrame(val width: Int = 320, val height: Int = 180) {
    private val chromaWidth = (width + 1) / 2
    private val chromaHeight = (height + 1) / 2

    val dataY: ByteBuffer = ByteBuffer.allocate(width * height)
    val dataU: ByteBuffer = ByteBuffer.allocate(chromaWidth * chromaHeight)
    val dataV: ByteBuffer = ByteBuffer.allocate(chromaWidth * chromaHeight)

    var releases = 0
        private set

    init {
        fillLuma { _, _ -> 200 }
        fillChroma(128, 128)
    }

    fun fillLuma(value: (Int, Int) -> Int) {
        for (row in 0 until height) {
            for (column in 0 until width) {
                dataY.put(row * width + column, value(column, row).toByte())
            }
        }
    }

    fun fillChroma(u: Int, v: Int) {
        for (index in 0 until chromaWidth * chromaHeight) {
            dataU.put(index, u.toByte())
            dataV.put(index, v.toByte())
        }
    }

    fun frame(): CameraFrame = CameraFrame(
        width = width,
        height = height,
        rotation = CameraFrameRotation.DEGREES_0,
        timestampNs = 0,
        source = {
            CameraFramePlanes(
                width = width,
                height = height,
                dataY = dataY, strideY = width,
                dataU = dataU, strideU = chromaWidth,
                dataV = dataV, strideV = chromaWidth,
                release = { releases += 1 },
            )
        },
    )
}

class ScriptedSegmenter(
    behavior: Behavior = Behavior.Immediate,
    private val clock: TestClock? = null,
    private val mask: () -> PersonMaskPixels = { makeMaskPixels() },
) : PersonSegmenting {
    sealed interface Behavior {
        data object Immediate : Behavior
        data object Failing : Behavior
        data object Deferred : Behavior
        data object Blocked : Behavior
        data class Advancing(val nanos: Long) : Behavior
    }

    override val quality = PersonMaskQuality.STREAM

    private val state = ReentrantLock()
    private val changed = state.newCondition()
    private var stored = behavior
    private var submitCount = 0
    private var finishCount = 0
    private var closeCount = 0
    private val inputSizes = mutableListOf<Pair<Int, Int>>()
    private var releasing = false
    private val held = mutableListOf<(Result<PersonMaskPixels>) -> Unit>()

    /** The most recent input, so a test can read what was copied into it. */
    var lastInput: PersonMaskInput? = null
        get() = state.withLock { field }
        private set

    var behavior: Behavior
        get() = state.withLock { stored }
        set(value) = state.withLock { stored = value }

    val submits: Int get() = state.withLock { submitCount }

    val closes: Int get() = state.withLock { closeCount }

    val inputs: List<Pair<Int, Int>> get() = state.withLock { inputSizes.toList() }

    override fun submit(
        input: PersonMaskInput,
        completion: (Result<PersonMaskPixels>) -> Unit,
    ) {
        val current = state.withLock {
            submitCount += 1
            inputSizes.add(input.width to input.height)
            lastInput = input
            changed.signalAll()
            stored
        }

        when (current) {
            Behavior.Immediate -> completion(Result.success(mask()))
            Behavior.Failing -> completion(Result.failure(ScriptedSegmenterFailure()))
            Behavior.Deferred -> state.withLock { held.add(completion) }
            Behavior.Blocked -> {
                val released = state.withLock {
                    try {
                        while (!releasing) changed.await()
                        true
                    } catch (_: InterruptedException) {
                        false
                    }
                }
                if (released) completion(Result.success(mask()))
            }
            is Behavior.Advancing -> {
                clock?.advance(current.nanos)
                completion(Result.success(mask()))
            }
        }

        state.withLock {
            finishCount += 1
            changed.signalAll()
        }
    }

    override fun close() = state.withLock {
        closeCount += 1
    }

    /** Lets every blocked and future submission answer. */
    fun release() = state.withLock {
        releasing = true
        changed.signalAll()
    }

    fun answerHeld() {
        val pending = state.withLock { held.toList().also { held.clear() } }
        for (completion in pending) completion(Result.success(mask()))
    }

    fun waitForSubmits(count: Int): Boolean = waitUntil { submitCount >= count }

    fun waitForFinishes(count: Int): Boolean = waitUntil { finishCount >= count }

    private fun waitUntil(reached: () -> Boolean): Boolean = state.withLock {
        var remaining = TimeUnit.SECONDS.toNanos(5)
        while (!reached()) {
            if (remaining <= 0) return false
            remaining = changed.awaitNanos(remaining)
        }
        true
    }
}
