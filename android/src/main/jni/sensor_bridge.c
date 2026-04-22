#include <jni.h>
#include <stdint.h>

// Shared state — Kotlin writes, Dart reads via FFI.
// Encoded as Surface rotation convention:
//   0 = portraitUp, 1 = landscapeLeft, 2 = portraitDown, 3 = landscapeRight.
static int32_t g_device_orientation = 0;

// --- Dart FFI reads ---

int32_t ux_device_orientation(void) { return g_device_orientation; }

// --- Kotlin JNI writes ---

JNIEXPORT void JNICALL
Java_io_swipelab_ux_SensorBridge_nSetDeviceOrientation(JNIEnv *env, jclass cls, jint v) {
    g_device_orientation = v;
}
