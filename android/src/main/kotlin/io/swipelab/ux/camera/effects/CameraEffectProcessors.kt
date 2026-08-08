package io.swipelab.ux.camera.effects

/**
 * The production frame processor: every frame is offered to the mask producer
 * it owns and composited with the newest published mask. Nothing it returns is
 * the input frame.
 */
class CompositingEffectProcessor(
    private val compositor: CameraEffectCompositor,
    private val producer: PersonMaskProducer,
) : CameraEffectProcessor {
    override fun process(frame: CameraFrame): CameraFrameOutcome = try {
        producer.consider(frame)
        CameraFrameOutcome(compositor.composite(frame, producer.mask), this)
    } finally {
        frame.release()
    }

    override fun retire() {
        producer.close()
        compositor.release()
    }
}

/**
 * Builds the host's processors: one compositor and one ML Kit-backed mask
 * producer per effect.
 */
class CameraEffectProcessors(
    private val segmenters: () -> PersonSegmenting = { MlKitPersonSegmenter() },
) : CameraEffectProcessorFactory {
    override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor =
        CompositingEffectProcessor(
            compositor = CameraEffectCompositor(effect),
            producer = PersonMaskProducer(segmenters()),
        )
}
