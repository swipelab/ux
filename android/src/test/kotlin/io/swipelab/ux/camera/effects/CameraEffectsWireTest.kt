package io.swipelab.ux.camera.effects

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraEffectsWireTest {
    @Test
    fun decodesTheThreeMethods() {
        assertEquals(
            CameraEffectsDecoding.Request(CameraEffectsRequest.Available),
            CameraEffectsWire.decode("available", null),
        )
        assertEquals(
            CameraEffectsDecoding.Request(
                CameraEffectsRequest.SetEffect("t1", CameraEffect.BLUR, 3)
            ),
            CameraEffectsWire.decode(
                "setEffect",
                mapOf("trackId" to "t1", "effect" to "blur", "generation" to 3),
            ),
        )
        assertEquals(
            CameraEffectsDecoding.Request(CameraEffectsRequest.Clear(4)),
            CameraEffectsWire.decode("clear", mapOf("generation" to 4)),
        )
        assertEquals(
            CameraEffectsDecoding.UnknownMethod,
            CameraEffectsWire.decode("blorp", null),
        )
    }

    @Test
    fun rejectsBadSetEffectArguments() {
        fun invalidOf(decoding: CameraEffectsDecoding) =
            (decoding as CameraEffectsDecoding.Invalid).failure.code

        assertEquals(
            "invalid_response",
            invalidOf(CameraEffectsWire.decode("setEffect", null)),
        )
        assertEquals(
            "invalid_response",
            invalidOf(
                CameraEffectsWire.decode(
                    "setEffect",
                    mapOf("trackId" to "t1", "effect" to "none", "generation" to 1),
                )
            ),
        )
        assertEquals(
            "invalid_response",
            invalidOf(
                CameraEffectsWire.decode(
                    "setEffect",
                    mapOf("trackId" to "t1", "effect" to "sparkle", "generation" to 1),
                )
            ),
        )
        assertEquals(
            "invalid_response",
            invalidOf(
                CameraEffectsWire.decode(
                    "setEffect",
                    mapOf("trackId" to "t1", "effect" to "blur"),
                )
            ),
        )
        assertEquals(
            "invalid_response",
            invalidOf(CameraEffectsWire.decode("clear", null)),
        )
    }

    @Test
    fun encodesStatusWithTheCodeOnlyWhenPresent() {
        assertEquals(
            mapOf("phase" to "active", "effect" to "blur", "generation" to 5),
            CameraEffectsWire.encode(
                CameraEffectStatus.active(CameraEffect.BLUR, 5)
            ),
        )
        assertEquals(
            mapOf(
                "phase" to "failed",
                "effect" to "dim",
                "generation" to 6,
                "code" to "processing_failed",
            ),
            CameraEffectsWire.encode(
                CameraEffectStatus.failed(CameraEffect.DIM, 6, "processing_failed")
            ),
        )
    }
}
