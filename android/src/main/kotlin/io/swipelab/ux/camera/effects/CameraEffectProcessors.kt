package io.swipelab.ux.camera.effects

/** How much of the pipeline a processor runs. */
enum class CameraEffectStage(val wireName: String) {
    /** The frame crosses the bridge and is copied; no mask, no effect. */
    PASSTHROUGH("passthrough"),

    /** The mask producer runs and the copy ignores what it publishes. */
    MASK_ONLY("mask-only"),

    /** The effect renders under the mask. */
    COMPOSITE("composite");

    companion object {
        fun fromWire(name: String): CameraEffectStage? =
            entries.firstOrNull { it.wireName == name }
    }
}

/**
 * The production frame processor: every frame is offered to the mask producer
 * it owns and composited with the newest published mask. Nothing it returns is
 * the input frame.
 */
class CompositingEffectProcessor(
    private val compositor: CameraEffectCompositor,
    private val producer: PersonMaskProducer,
) : CameraEffectProcessor {
    override fun process(frame: CameraFrame): CameraFrameOutcome = frame.use {
        producer.consider(frame)
        CameraFrameOutcome(compositor.composite(frame, producer.mask), this)
    }

    override fun retire() {
        producer.close()
        compositor.retire()
    }
}

/**
 * A processor stopping short of the production path: the composite takes no
 * mask, and a mask producer runs only when one is given.
 */
class StagedEffectProcessor(
    private val compositor: CameraEffectCompositor,
    private val producer: PersonMaskProducer?,
) : CameraEffectProcessor {
    override fun process(frame: CameraFrame): CameraFrameOutcome = frame.use {
        producer?.consider(frame)
        CameraFrameOutcome(compositor.composite(frame, null), this)
    }

    override fun retire() {
        producer?.close()
        compositor.retire()
    }
}

/**
 * Builds the host's processors: one compositor and one ML Kit-backed mask
 * producer per effect. [stage] is what [CameraEffectsRig] moves to price one
 * part of the pipeline at a time; every processor built after it changes runs
 * that much.
 */
class CameraEffectProcessors(
    private val segmenters: () -> PersonSegmenting = { MlKitPersonSegmenter() },
) : CameraEffectProcessorFactory {
    internal var stage: CameraEffectStage = CameraEffectStage.COMPOSITE

    override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor = when (stage) {
        CameraEffectStage.COMPOSITE -> CompositingEffectProcessor(
            compositor = CameraEffectCompositor(effect),
            producer = PersonMaskProducer(segmenters()),
        )

        CameraEffectStage.MASK_ONLY -> StagedEffectProcessor(
            compositor = CameraEffectCompositor(CameraEffect.NONE),
            producer = PersonMaskProducer(segmenters()),
        )

        CameraEffectStage.PASSTHROUGH -> StagedEffectProcessor(
            compositor = CameraEffectCompositor(CameraEffect.NONE),
            producer = null,
        )
    }
}
