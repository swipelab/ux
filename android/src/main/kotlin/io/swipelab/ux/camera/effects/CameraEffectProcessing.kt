package io.swipelab.ux.camera.effects

/** Why a composite answered with a substitute instead of a rendered frame. */
enum class CameraCompositeSubstitution {
    MALFORMED_FRAME,
    POOL_UNAVAILABLE,
    RENDER_FAILED,
}

/** Why a mask was set aside and the whole frame took the effect. */
enum class CameraMaskRejection {
    EMPTY,
    INVALID_STORAGE,
    ZERO_DIMENSIONED,
    SOURCE_RECT_MISMATCH,
}

/** One frame's result: the frame the track publishes and how it was produced. */
sealed interface CompositeOutcome {
    val frame: CameraFrame

    /**
     * A rendered frame; a set-aside mask records why the whole frame took the
     * effect.
     */
    data class Composited(
        override val frame: CameraFrame,
        val maskRejection: CameraMaskRejection? = null,
    ) : CompositeOutcome

    /**
     * A fail-closed substitute — the last-good effected frame or black,
     * never the input.
     */
    data class Substituted(
        override val frame: CameraFrame,
        val reason: CameraCompositeSubstitution,
    ) : CompositeOutcome
}

/**
 * One frame's result together with the processor that produced it, so the
 * service can drop outcomes arriving from a processor it no longer holds.
 */
class CameraFrameOutcome(
    val outcome: CompositeOutcome,
    val processor: CameraEffectProcessor,
) {
    val frame: CameraFrame get() = outcome.frame
}

/**
 * Turns a camera frame into the frame the track publishes and reports what
 * that frame produced. [retire] releases what the processor holds for its
 * effect; a [process] already in flight completes and returns its output.
 */
interface CameraEffectProcessor {
    fun process(frame: CameraFrame): CameraFrameOutcome
    fun retire()
}

/**
 * Stands up the processor for an effect. A `null` factory is a host below
 * the capability's floor: every command answers `unsupported`.
 */
interface CameraEffectProcessorFactory {
    @Throws(Exception::class)
    fun makeProcessor(effect: CameraEffect): CameraEffectProcessor
}

/** Publishes the camera's own frames. */
class PassthroughEffectProcessor : CameraEffectProcessor {
    override fun process(frame: CameraFrame) =
        CameraFrameOutcome(CompositeOutcome.Composited(frame), this)

    override fun retire() {}
}

class PassthroughEffectProcessors : CameraEffectProcessorFactory {
    override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor =
        PassthroughEffectProcessor()
}
