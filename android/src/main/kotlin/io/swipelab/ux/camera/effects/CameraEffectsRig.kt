package io.swipelab.ux.camera.effects

import io.swipelab.ux.BuildConfig

/**
 * The benchmark rig's lever on the pipeline, for attributing power and heat
 * one stage at a time.
 *
 * ```kotlin
 * CameraEffectsRig.engage(CameraEffectStage.PASSTHROUGH)
 * ```
 *
 * A release build holds [CameraEffectStage.COMPOSITE]: [engage] answers false
 * and moves nothing.
 */
object CameraEffectsRig {
    fun engage(stage: CameraEffectStage): Boolean {
        if (!BuildConfig.DEBUG) return false
        CameraEffects.processors.stage = stage
        return true
    }
}
