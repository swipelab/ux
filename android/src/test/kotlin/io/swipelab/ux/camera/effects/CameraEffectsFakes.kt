package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer

fun makeCameraFrame(timestampNs: Long = 0): CameraFrame = CameraFrame(
    width = 2,
    height = 2,
    rotation = CameraFrameRotation.DEGREES_0,
    timestampNs = timestampNs,
    source = {
        CameraFramePlanes(
            width = 2,
            height = 2,
            dataY = ByteBuffer.allocate(4), strideY = 2,
            dataU = ByteBuffer.allocate(1), strideU = 1,
            dataV = ByteBuffer.allocate(1), strideV = 1,
            release = {},
        )
    },
)

/**
 * The host's tracks, which outlive any one bridge: a track takes as many
 * processing callbacks as are put on it, and only the object currently under
 * an id can be reached by that id.
 */
class FakeTrackWorld {
    class Track(val id: String) {
        val registrations = mutableListOf<FakeCameraTrackBridge.Attachment>()
    }

    private val tracks = mutableMapOf<String, Track>()

    fun track(id: String): Track = tracks.getOrPut(id) { Track(id) }

    fun current(id: String): Track? = tracks[id]

    /** The id comes to name a different track object. */
    fun replaceTrack(id: String) {
        tracks[id] = Track(id)
    }

    /** The track dies: nothing answers to `id`, and its callbacks die with it. */
    fun removeTrack(id: String) {
        tracks[id]?.registrations?.clear()
        tracks.remove(id)
    }

    fun registrations(id: String): Int = tracks[id]?.registrations?.size ?: 0
}

class FakeCameraTrackBridge(
    val world: FakeTrackWorld = FakeTrackWorld(),
) : CameraTrackBridging {

    class Attachment(
        val track: FakeTrackWorld.Track,
        var processing: ((CameraFrame) -> CameraFrame)?,
    ) : CameraTrackAttachment {
        override val trackId: String get() = track.id

        fun deliverFrame(frame: CameraFrame = makeCameraFrame()): CameraFrame? =
            processing?.invoke(frame)
    }

    var attachException: CameraTrackAttachException? = null

    var attachCount = 0
        private set
    var detachCount = 0
        private set
    var teardownCount = 0
        private set
    val outcomes = mutableListOf<CameraTrackDetachOutcome>()

    private val attachments = mutableListOf<Attachment>()

    /** The attachments whose callback is still registered on its track. */
    val live: List<Attachment>
        get() = attachments.filter { attachment ->
            attachment.track.registrations.any { it === attachment }
        }

    override fun attach(
        trackId: String,
        processing: (CameraFrame) -> CameraFrame,
    ): CameraTrackAttachment {
        attachCount += 1
        attachException?.let { throw it }
        val track = world.track(trackId)
        val attachment = Attachment(track, processing)
        track.registrations.add(attachment)
        attachments.add(attachment)
        return attachment
    }

    override fun detach(attachment: CameraTrackAttachment): CameraTrackDetachOutcome {
        detachCount += 1
        val registration = attachment as? Attachment
            ?: return record(CameraTrackDetachOutcome.ALREADY_GONE)
        val current = world.current(registration.trackId)
            ?: return record(CameraTrackDetachOutcome.ALREADY_GONE)
        if (current !== registration.track) {
            return record(CameraTrackDetachOutcome.TRACK_REPLACED)
        }
        current.registrations.removeAll { it === registration }
        registration.processing = null
        return record(CameraTrackDetachOutcome.REMOVED)
    }

    override fun teardown() {
        teardownCount += 1
        for (attachment in attachments) {
            attachment.track.registrations.removeAll { it === attachment }
            attachment.processing = null
        }
        attachments.clear()
    }

    private fun record(outcome: CameraTrackDetachOutcome): CameraTrackDetachOutcome {
        outcomes.add(outcome)
        return outcome
    }
}

class FakeScheduler : CameraEffectsScheduling {
    class Work(val body: () -> Unit) : CameraEffectsScheduledWork {
        var cancelled = false
            private set

        override fun cancel() {
            cancelled = true
        }

        fun fire() {
            if (!cancelled) body()
        }
    }

    val scheduled = mutableListOf<Work>()

    override fun schedule(delayMillis: Long, body: () -> Unit): CameraEffectsScheduledWork =
        Work(body).also { scheduled.add(it) }

    /** Fires the most recently scheduled, uncancelled work. */
    fun fireLast() {
        scheduled.lastOrNull { !it.cancelled }?.fire()
    }
}

class ImmediateDelivery : CameraEffectsDelivering {
    override fun deliver(body: () -> Unit) = body()
}

class SubstitutingProcessor : CameraEffectProcessor {
    var retired = false
        private set

    override fun process(frame: CameraFrame) =
        CameraFrameOutcome(
            CompositeOutcome.Substituted(frame, CameraCompositeSubstitution.RENDER_FAILED),
            this,
        )

    override fun retire() {
        retired = true
    }
}

/**
 * Composites until [substitute] flips, then substitutes. [beforeOutcome]
 * runs inside `process`, between taking the frame and returning — where a
 * concurrent command lands relative to an in-flight frame.
 */
class FlippableProcessor : CameraEffectProcessor {
    var substitute = false
    var beforeOutcome: (() -> Unit)? = null
    var retired = false
        private set

    override fun process(frame: CameraFrame): CameraFrameOutcome {
        beforeOutcome?.invoke()
        return CameraFrameOutcome(
            if (substitute) {
                CompositeOutcome.Substituted(frame, CameraCompositeSubstitution.RENDER_FAILED)
            } else {
                CompositeOutcome.Composited(frame)
            },
            this,
        )
    }

    override fun retire() {
        retired = true
    }
}

class RecordingProcessorFactory : CameraEffectProcessorFactory {
    val made = mutableListOf<FlippableProcessor>()
    var makeException: Exception? = null

    override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor {
        makeException?.let { throw it }
        return FlippableProcessor().also { made.add(it) }
    }
}
