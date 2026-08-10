package io.swipelab.ux.camera.effects

fun makeCameraFrame(timestampNs: Long = 0): CameraFrame =
    EffectFrame(width = 64, height = 36, timestampNs = timestampNs).frame()

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
        var processing: ((CameraFrame) -> PublishedFrame)?,
    ) : CameraTrackAttachment {
        override val trackId: String get() = track.id

        fun deliverFrame(frame: CameraFrame = makeCameraFrame()): PublishedFrame? =
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
        processing: (CameraFrame) -> PublishedFrame,
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

/**
 * A bridge that counts every obligation the ownership contract places on a
 * host: inputs constructed, readbacks performed, input plane releases the core
 * caused, `processing` calls, publications received and closed. A host frame it
 * cannot represent is published as it stands.
 */
class CountingTrackBridge(
    private val width: Int = 64,
    private val height: Int = 36,
) : CameraTrackBridging {
    /** One frame of the host's own, which the bridge may or may not represent. */
    class HostFrame(val representable: Boolean = true) {
        var publishedUnchanged = false
            internal set
    }

    class Registration(
        override val trackId: String,
        var processing: ((CameraFrame) -> PublishedFrame)?,
    ) : CameraTrackAttachment

    var inputsConstructed = 0
        private set
    var readbacks = 0
        private set
    var inputPlaneReleases = 0
        private set
    var processingCalls = 0
        private set
    var publicationsReceived = 0
        private set
    var publicationsClosed = 0
        private set
    var teardownCount = 0
        private set

    private val held = mutableListOf<PublishedFrame>()
    private val registrations = mutableListOf<Registration>()

    val liveRegistrations: Int get() = registrations.size

    val outstandingPublications: Int get() = held.size

    override fun attach(
        trackId: String,
        processing: (CameraFrame) -> PublishedFrame,
    ): CameraTrackAttachment = Registration(trackId, processing).also { registrations.add(it) }

    override fun detach(attachment: CameraTrackAttachment): CameraTrackDetachOutcome {
        val registration = attachment as? Registration
            ?: return CameraTrackDetachOutcome.ALREADY_GONE
        registrations.removeAll { it === registration }
        registration.processing = null
        return CameraTrackDetachOutcome.REMOVED
    }

    override fun teardown() {
        teardownCount += 1
        for (registration in registrations) registration.processing = null
        registrations.clear()
    }

    /** The capture callback: one host frame across the bridge and back. */
    fun deliver(host: HostFrame = HostFrame()) {
        val processing = registrations.lastOrNull()?.processing ?: return
        if (!host.representable) {
            host.publishedUnchanged = true
            return
        }
        processingCalls += 1
        held.add(processing(input()))
        publicationsReceived += 1
    }

    /** The downstream consumer finishing with the planes it was handed. */
    fun releasePublications() {
        for (published in held) {
            published.close()
            publicationsClosed += 1
        }
        held.clear()
    }

    private fun input(): CameraFrame {
        inputsConstructed += 1
        val source = EffectFrame(width = width, height = height)
        return CameraFrame(
            width = width,
            height = height,
            rotation = CameraFrameRotation.DEGREES_0,
            timestampNs = 0,
        ) {
            readbacks += 1
            CameraFramePlanes(
                width = width,
                height = height,
                dataY = source.dataY, strideY = source.strideY,
                dataU = source.dataU, strideU = source.strideChroma,
                dataV = source.dataV, strideV = source.strideChroma,
                onRelease = { inputPlaneReleases += 1 },
            )
        }
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

/**
 * Publishes through a real compositor, so the service tests exercise the
 * production claim protocol; [substitute] decides only how the outcome is
 * classified. [beforeOutcome] runs inside `process`, before the composite —
 * where a concurrent command lands relative to an in-flight frame.
 */
class FlippableProcessor : CameraEffectProcessor {
    val pools = ScriptedBufferPools()

    private val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)

    var substitute = false
    var beforeOutcome: (() -> Unit)? = null
    var retires = 0
        private set

    val retired: Boolean get() = retires > 0

    /** Every pooled claim this processor took has come back. */
    val balanced: Boolean get() = pools.pools.all { it.taken == it.recycled }

    override fun process(frame: CameraFrame): CameraFrameOutcome = frame.use {
        beforeOutcome?.invoke()
        val rendered = compositor.composite(frame, null) as CompositeOutcome.Composited
        CameraFrameOutcome(
            if (substitute) {
                CompositeOutcome.Substituted(
                    rendered.frame,
                    CameraCompositeSubstitution.RENDER_FAILED,
                    CameraCompositeSubstitute.LAST_GOOD,
                )
            } else {
                rendered
            },
            this,
            null,
            if (substitute) {
                CameraCompositeUse.Substituted(
                    CameraCompositeSubstitution.RENDER_FAILED,
                    CameraCompositeSubstitute.LAST_GOOD,
                )
            } else {
                CameraCompositeUse.Maskless
            },
        )
    }

    override fun retire() {
        retires += 1
        compositor.retire()
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
