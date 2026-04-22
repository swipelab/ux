package io.swipelab.ux

object SensorBridge {
    init {
        System.loadLibrary("ux_keyboard")
    }

    @JvmStatic external fun nSetDeviceOrientation(v: Int)
}
