package io.swipelab.ux.camera.effects

/** One published-frame record keyed by [generation] and [frameTimestampNs]. */
data class CameraCompositeRecord(
    val generation: Int,
    val frameTimestampNs: Long,

    /** The timestamp of the frame the mask was inferred from, if there was one. */
    val maskFrameTimestampNs: Long?,

    val use: CameraCompositeUse,

    /** Absent when the frame published a substitute rather than a render. */
    val background: CameraBackgroundGrid?,
)

/**
 * The composites the rig can still read, oldest first. Reading takes nothing
 * out, so a window widened after the fact still finds its records; a record
 * leaves only once [capacity] later ones sit on top of it. A log built with
 * `exposes` false keeps nothing at all.
 */
class CameraCompositeLog(
    private val exposes: Boolean,
    private val capacity: Int = CAPACITY,
) {
    companion object {
        const val CAPACITY = 512
    }

    private val entries = ArrayDeque<CameraCompositeRecord>()

    fun record(record: CameraCompositeRecord) {
        if (!exposes) return
        synchronized(entries) {
            if (entries.size == capacity) entries.removeFirst()
            entries.addLast(record)
        }
    }

    fun records(): List<CameraCompositeRecord> = synchronized(entries) { entries.toList() }
}
