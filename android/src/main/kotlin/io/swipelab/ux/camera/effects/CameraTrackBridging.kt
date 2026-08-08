package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer

/** A camera frame's rotation: one of four quarter turns, and nothing else. */
enum class CameraFrameRotation(val degrees: Int) {
    DEGREES_0(0),
    DEGREES_90(90),
    DEGREES_180(180),
    DEGREES_270(270);

    companion object {
        fun fromDegrees(degrees: Int): CameraFrameRotation? =
            entries.firstOrNull { it.degrees == degrees }
    }
}

/**
 * CPU pixels of one frame, I420. The buffers stay valid until the frame
 * holding them is closed, which is the only thing that gives them up.
 */
class CameraFramePlanes(
    val width: Int,
    val height: Int,
    val dataY: ByteBuffer,
    val strideY: Int,
    val dataU: ByteBuffer,
    val strideU: Int,
    val dataV: ByteBuffer,
    val strideV: Int,
    private val onRelease: () -> Unit,
) {
    internal fun release() = onRelease()
}

/**
 * One frame the host hands the core. [planes] resolves CPU pixels on the first
 * ask and memoizes that outcome — for a host frame the source costs a texture
 * readback, so it runs at most once. [close] is terminal and gives up only
 * planes successfully materialized through this frame.
 */
class CameraFrame(
    val width: Int,
    val height: Int,
    val rotation: CameraFrameRotation,
    val timestampNs: Long,
    private val source: () -> CameraFramePlanes,
) : AutoCloseable {
    private val lock = Any()
    private var materialized: CameraFramePlanes? = null
    private var materializationFailure: Throwable? = null
    private var closed = false

    fun planes(): CameraFramePlanes = synchronized(lock) {
        check(!closed) { "Camera frame is closed" }
        materialized?.let { return@synchronized it }
        materializationFailure?.let { throw it }
        try {
            source().also { materialized = it }
        } catch (failure: Throwable) {
            materializationFailure = failure
            throw failure
        }
    }

    override fun close() {
        val planes = synchronized(lock) {
            if (closed) return
            closed = true
            materialized
        }
        planes?.release()
    }
}

/**
 * One frame the core hands back, over planes it already holds. [close] gives
 * up the core's publication.
 */
class PublishedFrame(
    val width: Int,
    val height: Int,
    val rotation: CameraFrameRotation,
    val timestampNs: Long,
    val planes: CameraFramePlanes,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
        }
        planes.release()
    }
}

/**
 * A processing callback the bridge holds, handed back to remove that exact
 * callback. It names the track it was created for.
 */
interface CameraTrackAttachment {
    val trackId: String
}

/** What removing a callback found. */
enum class CameraTrackDetachOutcome {
    REMOVED,

    /** The track died under the attachment. */
    ALREADY_GONE,

    /**
     * The id now names a different track, which never took the callback. The
     * track that did keeps it until it dies.
     */
    TRACK_REPLACED,
}

/** Why a track would not take a processing callback. */
class CameraTrackAttachException(val unknownTrack: Boolean) : Exception()

/**
 * The host's camera stack, as the effects core needs it: install a processing
 * callback on one track, remove it by identity, release everything on
 * teardown.
 *
 * **Ownership.** Every frame crossing the bridge is released exactly once, by
 * the party it was transferred to; its direction names that party. Ownership
 * follows the transfer, not who materialized the pixels.
 *
 * - For every host frame it can represent, the bridge constructs one
 *   [CameraFrame] and transfers it to `processing`. The core owns it from that
 *   call and closes it exactly once on every return and every failure path
 *   before `processing` returns. The host neither closes the frame nor its
 *   planes, and does not touch the frame after `processing` returns.
 * - Planes materialize lazily: the frame invokes the host source at most once,
 *   and only when the core needs the pixels. A frame the core short-circuits
 *   never materializes, so a readback that was never performed is never
 *   released. The host supplies the closure that gives the underlying buffer
 *   back and never invokes it directly.
 * - `processing` returns a [PublishedFrame] — always distinct from its input,
 *   never over the host's raw pixels, over planes the core already holds. The
 *   host owns it from that return and closes it exactly once, after the
 *   downstream consumer has finished with its planes. For a host that wraps
 *   those planes for a downstream consumer, "after" is that consumer's release
 *   callback, not the return of the capture callback.
 * - For a host frame the bridge cannot represent, the bridge constructs no
 *   [CameraFrame], does not call `processing`, and publishes the host frame
 *   unchanged.
 * - `processing` does not throw.
 */
interface CameraTrackBridging {
    @Throws(CameraTrackAttachException::class)
    fun attach(
        trackId: String,
        processing: (CameraFrame) -> PublishedFrame,
    ): CameraTrackAttachment

    fun detach(attachment: CameraTrackAttachment): CameraTrackDetachOutcome

    /**
     * Releases everything the bridge holds. It arrives after the detach of a
     * live attachment, and never while the bridge is still installed.
     */
    fun teardown()
}
