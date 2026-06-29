# Consumer ProGuard/R8 rules shipped with the ux AAR — merged into the
# consuming app's R8 run automatically.
#
# The vendored FFmpeg software H.264 decoder (android/ffmpeg/ffmpeg_jni.cc)
# reaches into Media3's VideoDecoderOutputBuffer entirely from native code:
# JNI_OnLoad resolves initForYuvFrame() and the data/decoderPrivate/timeUs
# fields via GetMethodID/GetFieldID by name. R8 can't see those native-only
# accesses, considers the members dead, and strips them in minified (release)
# builds. JNI_OnLoad then fails its GetMethodID lookup, System.loadLibrary
# throws, and FfmpegLibrary.isAvailable() returns false — silently disabling
# the FFmpeg renderer in release while debug (no R8) works. On HiSilicon
# (Huawei/EMUI) devices, where the FFmpeg path is the only decoder that
# handles iOS full-range H.264, that manifests as video failing to play.
#
# Keep every member the JNI looks up by name. (R8's default
# `-keepclasseswithmembernames class * { native <methods>; }` already covers
# FfmpegLibrary's own native methods; this only adds the Media3 side.)
-keep class androidx.media3.decoder.VideoDecoderOutputBuffer { *; }
-keepclassmembers class androidx.media3.decoder.DecoderOutputBuffer {
    long timeUs;
}
