package io.swipelab.ux.camera.effects

/** Why a composite answered with a substitute instead of a rendered frame. */
enum class CameraCompositeSubstitution {
    MALFORMED_FRAME,
    POOL_UNAVAILABLE,
    RENDER_FAILED,
}

enum class CameraCompositeSubstitute {
    LAST_GOOD,
    BLACK,
}

/** Why a mask was set aside and the whole frame took the effect. */
enum class CameraMaskRejection {
    EMPTY,
    INVALID_STORAGE,
    ZERO_DIMENSIONED,
    SOURCE_RECT_MISMATCH,
}

/**
 * How much of the composite each cell of a [SIZE]-square grid over the frame
 * took from the effect: the mean, over the cell's luma pixels, of the
 * background weight the blend applied — 1 where the effect covered the cell
 * whole and 0 where the person did.
 *
 * Cells are half-open pixel rectangles that partition the frame; a cell no
 * pixel falls in holds 0.
 */
class CameraBackgroundGrid(fractions: FloatArray) {
    companion object {
        const val SIZE = 16
        const val CELLS = SIZE * SIZE

        /** The first pixel of cell [index] along an axis [extent] pixels long. */
        fun edge(index: Int, extent: Int): Int = index * extent / SIZE
    }

    private val cells = fractions.copyOf()

    init {
        require(cells.size == CELLS)
    }

    fun fraction(column: Int, row: Int): Float = cells[row * SIZE + column]
}

/** One frame's result: the frame the track publishes and how it was produced. */
sealed interface CompositeOutcome {
    val frame: PublishedFrame

    /**
     * A rendered frame; a set-aside mask records why the whole frame took the
     * effect.
     */
    data class Composited(
        override val frame: PublishedFrame,
        val background: CameraBackgroundGrid,
        val maskRejection: CameraMaskRejection? = null,
    ) : CompositeOutcome

    /**
     * A fail-closed substitute — the last-good effected frame or black,
     * never the input.
     */
    data class Substituted(
        override val frame: PublishedFrame,
        val reason: CameraCompositeSubstitution,
        val substitute: CameraCompositeSubstitute,
    ) : CompositeOutcome
}

/** The processor's classification of its mask snapshot for one published frame. */
sealed interface CameraCompositeUse {
    /** The snapshot passes the structural applicability predicate. */
    data object Used : CameraCompositeUse

    /** The mask is structurally inapplicable to the frame. */
    data class Rejected(val reason: CameraMaskRejection) : CameraCompositeUse

    /** No render happened; the frame published a substitute. */
    data class Substituted(
        val reason: CameraCompositeSubstitution,
        val substitute: CameraCompositeSubstitute,
    ) : CameraCompositeUse

    /** The processor held no mask when the frame arrived. */
    data object Maskless : CameraCompositeUse
}

/**
 * One frame's result together with the processor that produced it, so the
 * service can drop outcomes arriving from a processor it no longer holds.
 * [mask] is the object the processor snapshotted for this frame, which [use]
 * describes the fate of.
 */
class CameraFrameOutcome(
    val outcome: CompositeOutcome,
    val processor: CameraEffectProcessor,
    val mask: CameraMask?,
    val use: CameraCompositeUse,
) {
    val frame: PublishedFrame get() = outcome.frame
}

/**
 * The render a processor drives. Injected so a test sees the exact mask object
 * a composite was handed.
 */
interface CameraCompositing {
    fun composite(frame: CameraFrame, mask: CameraMask?): CompositeOutcome
    fun retire()
}

/**
 * Turns a camera frame into the frame the track publishes and reports what
 * that frame produced. [retire] closes what the processor holds that needs a
 * deterministic close; a processor still reachable from a callback answers
 * every frame it is given.
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
