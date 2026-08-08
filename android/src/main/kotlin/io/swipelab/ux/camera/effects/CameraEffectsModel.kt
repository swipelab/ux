package io.swipelab.ux.camera.effects

/** What the outgoing camera track carries behind the person. */
enum class CameraEffect(val wireName: String) {
    NONE("none"),
    BLUR("blur"),
    DIM("dim");

    companion object {
        fun fromWire(name: String): CameraEffect? =
            entries.firstOrNull { it.wireName == name }
    }
}

/** How far an effect has got. */
enum class CameraEffectPhase(val wireName: String) {
    IDLE("idle"),
    APPLYING("applying"),
    ACTIVE("active"),
    FAILED("failed"),
}

/**
 * The effect on the track, the phase it is in, and the generation of the
 * last command the platform took.
 */
data class CameraEffectStatus(
    val phase: CameraEffectPhase,
    val effect: CameraEffect,
    val generation: Int,
    val code: String? = null,
) {
    companion object {
        fun idle(generation: Int) =
            CameraEffectStatus(CameraEffectPhase.IDLE, CameraEffect.NONE, generation)

        fun applying(effect: CameraEffect, generation: Int) =
            CameraEffectStatus(CameraEffectPhase.APPLYING, effect, generation)

        fun active(effect: CameraEffect, generation: Int) =
            CameraEffectStatus(CameraEffectPhase.ACTIVE, effect, generation)

        fun failed(effect: CameraEffect, generation: Int, code: String) =
            CameraEffectStatus(CameraEffectPhase.FAILED, effect, generation, code)
    }
}

/** Codes that ride the status stream and are never thrown. */
object CameraEffectStatusCode {
    /** Processing stopped after the effect was active. */
    const val PROCESSING_FAILED = "processing_failed"
}

/** A command the channel cannot serve, carrying the code Dart raises. */
data class CameraEffectsFailure(
    val code: String,
    val message: String? = null,
) {
    companion object {
        val unsupported =
            CameraEffectsFailure("unsupported", "effects processors unavailable")

        val integrationUnavailable =
            CameraEffectsFailure("integration_unavailable", "no camera bridge installed")

        val trackNotFound =
            CameraEffectsFailure("track_not_found", "the bridge holds no such track")

        val trackNotProcessable = CameraEffectsFailure(
            "track_not_processable",
            "no frame reached the processor before the attach deadline",
        )

        val initializationFailed =
            CameraEffectsFailure("initialization_failed", "the processor did not start")

        fun invalidRequest(field: String, detail: String) =
            CameraEffectsFailure("invalid_response", "$field: $detail")
    }
}

/** A `ux/camera_effects` call, decoded. */
sealed interface CameraEffectsRequest {
    data object Available : CameraEffectsRequest
    data class SetEffect(
        val trackId: String,
        val effect: CameraEffect,
        val generation: Int,
    ) : CameraEffectsRequest

    data class Clear(val generation: Int) : CameraEffectsRequest
}

/** What a request answers with. */
sealed interface CameraEffectsReply {
    data class Flag(val value: Boolean) : CameraEffectsReply
    data object Done : CameraEffectsReply
    data class Failure(val failure: CameraEffectsFailure) : CameraEffectsReply
}

/** A method call as decoding leaves it. */
sealed interface CameraEffectsDecoding {
    data class Request(val request: CameraEffectsRequest) : CameraEffectsDecoding
    data class Invalid(val failure: CameraEffectsFailure) : CameraEffectsDecoding
    data object UnknownMethod : CameraEffectsDecoding
}
