package io.swipelab.ux

import android.app.Activity
import android.view.OrientationEventListener
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

class SensorPlugin : NativePlugin {
    private var listener: OrientationEventListener? = null
    private var current: Int = 0

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding.activity)
    }

    override fun onDetachedFromActivity() {
        detach()
    }

    private fun attach(activity: Activity) {
        detach()
        val l = object : OrientationEventListener(activity) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees == ORIENTATION_UNKNOWN) return
                val bucket = bucketFor(degrees, current)
                if (bucket == current) return
                current = bucket
                SensorBridge.nSetDeviceOrientation(bucket)
            }
        }
        if (l.canDetectOrientation()) l.enable()
        listener = l
    }

    private fun detach() {
        listener?.disable()
        listener = null
    }

    companion object {
        internal fun bucketFor(degrees: Int, previous: Int): Int {
            val d = ((degrees % 360) + 360) % 360
            return when {
                d in 0..30 || d in 330..359 -> 0
                d in 60..120                -> 3
                d in 150..210               -> 2
                d in 240..300               -> 1
                d in 31..59                 -> if (previous == 0 || previous == 3) previous else 0
                d in 121..149               -> if (previous == 3 || previous == 2) previous else 3
                d in 211..239               -> if (previous == 2 || previous == 1) previous else 2
                d in 301..329               -> if (previous == 1 || previous == 0) previous else 1
                else                        -> previous
            }
        }
    }
}
