#if os(macOS)

import FlutterMacOS
import AppKit
import ux_extension

public class XPlugin: NSObject, FlutterPlugin {
    private static var plugins: [NativePlugin] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        plugins = [
            FilePlugin(),
            CryptoPlugin(),
            ClipboardPlugin(),
            GalleryPlugin(),
            CameraPlugin(),
            AudioCapturePlugin(),
            AudioSinkPlugin(),
            UxVideoPlayerPlugin(),
            UxVideoExporterPlugin(),
            UrlPlugin(),
            NotificationsPlugin(),
            WindowPlugin(),
            ScreenSourcesPlugin(),
            CameraEffectsPlugin(),
            SecureStorePlugin(),
            DropPlugin(),
            AppGroupPlugin(),
            VideoProbePlugin(),
            ImageProbePlugin(),
        ]
        for plugin in plugins {
            plugin.register(with: registrar)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(FlutterMethodNotImplemented)
    }
}

#endif
