package io.swipelab.ux.camera.effects

import io.swipelab.ux.BuildConfig

/**
 * The benchmark rig's lever on the pipeline and its window onto what the
 * pipeline composited, for attributing power and heat one stage at a time and
 * for reading what each published frame made of its mask.
 *
 * ```kotlin
 * CameraEffectsRig.engage(CameraEffectStage.PASSTHROUGH)
 * ```
 *
 * A release build holds [CameraEffectStage.COMPOSITE] and records nothing:
 * [engage] answers false and moves nothing, [composites] answers empty.
 */
object CameraEffectsRig {
    fun engage(stage: CameraEffectStage): Boolean {
        if (!BuildConfig.DEBUG) return false
        CameraEffects.processors.stage = stage
        return true
    }

    /** Every composite the log still holds, oldest first. */
    fun composites(): List<CameraCompositeRecord> = CameraEffects.composites.records()
}
