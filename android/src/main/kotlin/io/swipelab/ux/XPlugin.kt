package io.swipelab.ux

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.swipelab.ux.camera.CameraPlugin
import io.swipelab.ux.video.VideoExporterPlugin
import io.swipelab.ux.video.VideoPlayerPlugin

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class XPlugin : FlutterPlugin, ActivityAware {
    private val plugins: List<NativePlugin> = listOf(
        KeyboardPlugin(),
        SensorPlugin(),
        FilePlugin(),
        CryptoPlugin(),
        ScannerPlugin(),
        ClipboardPlugin(),
        GalleryPlugin(),
        CameraPlugin(),
        VideoPlayerPlugin(),
        VideoProbePlugin(),
        ImageProbePlugin(),
        VideoExporterPlugin(),
        ShortcutsPlugin(),
        CrashPlugin(),
        UrlPlugin(),
        NotificationsPlugin(),
        WindowPlugin(),
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) =
        plugins.forEach { it.onAttachedToEngine(binding) }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) =
        plugins.forEach { it.onDetachedFromEngine(binding) }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) =
        plugins.forEach { it.onAttachedToActivity(binding) }

    override fun onDetachedFromActivity() =
        plugins.forEach { it.onDetachedFromActivity() }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        plugins.forEach { it.onReattachedToActivityForConfigChanges(binding) }

    override fun onDetachedFromActivityForConfigChanges() =
        plugins.forEach { it.onDetachedFromActivityForConfigChanges() }
}
