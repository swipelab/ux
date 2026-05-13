package io.swipelab.ux.camera

import android.content.Context
import android.view.OrientationEventListener
import android.view.Surface

/// Maps Android's `OrientationEventListener` (continuous 0–359° tilt
/// reports) onto the four discrete `DeviceOrientation` values Dart
/// expects. Emits a callback only on transitions, so the EventChannel
/// doesn't get flooded with per-degree updates.
///
/// Snaps to the nearest quadrant with a 22.5° hysteresis margin so
/// hand-held jitter near a boundary doesn't cause rapid flips.
class DeviceOrientationBridge(context: Context) {
    private val listener = object : OrientationEventListener(context) {
        override fun onOrientationChanged(degrees: Int) {
            if (degrees == ORIENTATION_UNKNOWN) return
            val next = snap(degrees) ?: return
            if (next != current) {
                current = next
                callback?.invoke(next)
            }
        }
    }

    /// Surface rotation (`Surface.ROTATION_0` … `ROTATION_270`). What
    /// CameraX `setTargetRotation` consumes. Polled by [PhotoCapture].
    var current: Int = Surface.ROTATION_0
        private set

    private var callback: ((Int) -> Unit)? = null

    fun start(onChange: (Int) -> Unit) {
        callback = onChange
        if (listener.canDetectOrientation()) listener.enable()
    }

    fun stop() {
        listener.disable()
        callback = null
    }

    private fun snap(degrees: Int): Int? = when {
        degrees in 0..44 || degrees in 315..359 -> Surface.ROTATION_0
        degrees in 45..134 -> Surface.ROTATION_270
        degrees in 135..224 -> Surface.ROTATION_180
        degrees in 225..314 -> Surface.ROTATION_90
        else -> null
    }
}

/// Wire-side encoding identical to the iOS plugin's
/// `DeviceOrientationFlutter`. The Dart side decodes this string back
/// into a `DeviceOrientation`.
fun surfaceRotationToFlutter(rotation: Int): String = when (rotation) {
    Surface.ROTATION_0 -> "portraitUp"
    Surface.ROTATION_90 -> "landscapeRight"
    Surface.ROTATION_180 -> "portraitDown"
    Surface.ROTATION_270 -> "landscapeLeft"
    else -> "portraitUp"
}

/// Reverse mapping for the `snapshotOrientation` argument that
/// `takePicture` / `startVideoRecording` pass in.
fun flutterToSurfaceRotation(raw: String): Int = when (raw) {
    "portraitUp" -> Surface.ROTATION_0
    "landscapeRight" -> Surface.ROTATION_90
    "portraitDown" -> Surface.ROTATION_180
    "landscapeLeft" -> Surface.ROTATION_270
    else -> Surface.ROTATION_0
}
