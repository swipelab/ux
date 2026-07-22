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

# Media3 touches API-31-only framework types (android.media.metrics.*)
# strictly behind `Util.SDK_INT >= 31` guards hosted in `...$Api31`-style
# inner classes. R8's horizontal class merging can fold those guard
# classes into always-loaded ones, making class-load-time resolution of
# android.media.metrics.LogSessionId fatal on API < 31
# (NoClassDefFoundError on Huawei/EMUI Android 10 the moment a codec
# spins up). Keeping the guard classes as distinct entities disables the
# merge; the SDK check then works as designed.
-keep class androidx.media3.**$Api* { *; }
-dontwarn android.media.metrics.LogSessionId

# The transformer module additionally threads LogSessionId through the
# method signatures of ~20 top-level classes (Codec factories, asset
# loaders, sample exporters — the editing-metrics plumbing), not just
# `$Api*` guard classes. R8 merging/inlining across those classes makes
# eagerly-loaded ones (e.g. SequenceAssetLoader) hard-fail verification
# on API < 31 with NoClassDefFoundError for LogSessionId the moment an
# export starts. Keep the package as shipped; it is small and only
# reachable from XVideoExporter.
-keep class androidx.media3.transformer.** { *; }
