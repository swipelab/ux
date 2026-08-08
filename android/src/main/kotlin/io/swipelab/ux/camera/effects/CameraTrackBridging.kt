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
 * CPU pixels of one frame, I420. The buffers stay valid until [release];
 * whoever materialized them calls it exactly once.
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
    val release: () -> Unit,
)

/**
 * One camera frame as it crosses the bridge. [planes] materializes CPU pixels
 * on the first ask — for a host frame that costs a texture readback, so a
 * processor that publishes the input untouched never asks. A processor that
 * produces new pixels returns a frame built over its own planes. [release] is
 * terminal and releases only planes already materialized through this frame.
 */
class CameraFrame(
    val width: Int,
    val height: Int,
    val rotation: CameraFrameRotation,
    val timestampNs: Long,
    private val source: () -> CameraFramePlanes,
) {
    private val lock = Any()
    private var materialized: CameraFramePlanes? = null
    private var released = false

    fun planes(): CameraFramePlanes = synchronized(lock) {
        check(!released) { "Camera frame is released" }
        materialized ?: source().also { materialized = it }
    }

    fun release() {
        val planes = synchronized(lock) {
            if (released) return
            released = true
            materialized
        }
        planes?.release?.invoke()
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
 * A frame the bridge cannot present as a [CameraFrame] does not reach
 * `processing`; the bridge publishes it as it stands.
 */
interface CameraTrackBridging {
    @Throws(CameraTrackAttachException::class)
    fun attach(
        trackId: String,
        processing: (CameraFrame) -> CameraFrame,
    ): CameraTrackAttachment

    fun detach(attachment: CameraTrackAttachment): CameraTrackDetachOutcome

    /**
     * Releases everything the bridge holds. It arrives after the detach of a
     * live attachment, and never while the bridge is still installed.
     */
    fun teardown()
}
