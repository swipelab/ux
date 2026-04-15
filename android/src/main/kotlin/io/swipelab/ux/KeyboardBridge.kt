package io.swipelab.ux

/// JNI bridge to the C globals that Dart reads via FFI.
object KeyboardBridge {
    init {
        System.loadLibrary("ux_keyboard")
    }

    @JvmStatic external fun nSetHeight(h: Double)
    @JvmStatic external fun nSetSystemHeight(h: Double)
    @JvmStatic external fun nGetSystemHeight(): Double
    @JvmStatic external fun nSetTracking(v: Int)
    @JvmStatic external fun nSetAnim(target: Double, duration: Double)
}
