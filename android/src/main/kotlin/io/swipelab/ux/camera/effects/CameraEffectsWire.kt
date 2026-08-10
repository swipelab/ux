package io.swipelab.ux.camera.effects

/** The `ux/camera_effects` argument and event shapes. */
object CameraEffectsWire {
    fun decode(method: String, arguments: Map<*, *>?): CameraEffectsDecoding =
        when (method) {
            "available" -> CameraEffectsDecoding.Request(CameraEffectsRequest.Available)
            "setEffect" -> decodeSetEffect(arguments)
            "clear" -> decodeClear(arguments)
            else -> CameraEffectsDecoding.UnknownMethod
        }

    fun encode(status: CameraEffectStatus): Map<String, Any> {
        val event = mutableMapOf<String, Any>(
            "phase" to status.phase.wireName,
            "effect" to status.effect.wireName,
            "generation" to status.generation,
        )
        status.code?.let { event["code"] = it }
        return event
    }

    private fun decodeSetEffect(arguments: Map<*, *>?): CameraEffectsDecoding {
        if (arguments == null) {
            return invalid("arguments", "missing")
        }
        val trackId = arguments["trackId"] as? String
            ?: return invalid("trackId", "expected String")
        val name = arguments["effect"] as? String
            ?: return invalid("effect", "expected String")
        val effect = CameraEffect.fromWire(name)
        if (effect == null || effect == CameraEffect.NONE) {
            return invalid("effect", "expected blur or dim")
        }
        val generation = arguments["generation"] as? Int
            ?: return invalid("generation", "expected Int")
        return CameraEffectsDecoding.Request(
            CameraEffectsRequest.SetEffect(trackId, effect, generation)
        )
    }

    private fun decodeClear(arguments: Map<*, *>?): CameraEffectsDecoding {
        val generation = arguments?.get("generation") as? Int
            ?: return invalid("generation", "expected Int")
        return CameraEffectsDecoding.Request(CameraEffectsRequest.Clear(generation))
    }

    private fun invalid(field: String, detail: String) =
        CameraEffectsDecoding.Invalid(CameraEffectsFailure.invalidRequest(field, detail))
}
