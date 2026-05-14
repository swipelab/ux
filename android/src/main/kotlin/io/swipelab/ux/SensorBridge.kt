package io.swipelab.ux

object SensorBridge {
    init {
        System.loadLibrary("ux")
    }

    @JvmStatic external fun nSetDeviceOrientation(v: Int)
}
