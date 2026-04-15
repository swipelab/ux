#include <jni.h>
#include <stdint.h>

// Shared state — Kotlin writes, Dart reads via FFI
static double g_keyboard_height = 0;
static double g_system_height = 0;
static int32_t g_is_tracking = 0;
static double g_anim_target = 0;
static double g_anim_duration = 0;
static int32_t g_anim_generation = 0;

// --- Dart FFI reads (same signatures as iOS) ---

double ux_keyboard_height(void) { return g_keyboard_height; }
double ux_system_keyboard_height(void) { return g_system_height; }
int32_t ux_is_tracking(void) { return g_is_tracking; }
double ux_keyboard_anim_target(void) { return g_anim_target; }
double ux_keyboard_anim_duration(void) { return g_anim_duration; }
int32_t ux_keyboard_anim_gen(void) { return g_anim_generation; }

// --- Stubs for Dart FFI parity with iOS ---

void ux_enable_interactive_dismiss(double inset) { (void)inset; }
void ux_disable_interactive_dismiss(void) {}

// --- Kotlin JNI writes ---

JNIEXPORT void JNICALL
Java_io_swipelab_ux_KeyboardBridge_nSetHeight(JNIEnv *env, jclass cls, jdouble h) {
    g_keyboard_height = h;
}

JNIEXPORT void JNICALL
Java_io_swipelab_ux_KeyboardBridge_nSetSystemHeight(JNIEnv *env, jclass cls, jdouble h) {
    g_system_height = h;
}

JNIEXPORT jdouble JNICALL
Java_io_swipelab_ux_KeyboardBridge_nGetSystemHeight(JNIEnv *env, jclass cls) {
    return g_system_height;
}

JNIEXPORT void JNICALL
Java_io_swipelab_ux_KeyboardBridge_nSetTracking(JNIEnv *env, jclass cls, jint v) {
    g_is_tracking = v;
}

JNIEXPORT void JNICALL
Java_io_swipelab_ux_KeyboardBridge_nSetAnim(JNIEnv *env, jclass cls, jdouble target, jdouble duration) {
    g_anim_target = target;
    g_anim_duration = duration;
    g_anim_generation++;
}
