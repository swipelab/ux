#if os(iOS)

import Flutter
import UIKit
import ux_extension

public class XPlugin: NSObject, FlutterPlugin {
    private static var plugins: [NativePlugin] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        plugins = [
            KeyboardPlugin(),
            SensorPlugin(),
            FilePlugin(),
            CryptoPlugin(),
            ScannerPlugin(),
            ClipboardPlugin(),
            GalleryPlugin(),
            CrashPlugin(),
            CameraPlugin(),
            AudioCapturePlugin(),
            AudioSinkPlugin(),
            UxVideoPlayerPlugin(),
            UxVideoExporterPlugin(),
            UrlPlugin(),
            WindowPlugin(),
            CameraEffectsPlugin(),
            ScreenSourcesPlugin(),
            SecureStorePlugin(),
            AppGroupPlugin(),
            VideoProbePlugin(),
            ImageProbePlugin(),
            ShortcutsPlugin(),
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
