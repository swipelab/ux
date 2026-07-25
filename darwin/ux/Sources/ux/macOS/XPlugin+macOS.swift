#if os(macOS)

import FlutterMacOS
import AppKit

public class XPlugin: NSObject, FlutterPlugin {
    private static var plugins: [NativePlugin] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        plugins = [
            FilePlugin(),
            CryptoPlugin(),
            ClipboardPlugin(),
            GalleryPlugin(),
            CameraPlugin(),
            UxVideoPlayerPlugin(),
            UxVideoExporterPlugin(),
            UrlPlugin(),
            NotificationsPlugin(),
            WindowPlugin(),
            DropPlugin(),
            AppGroupPlugin(),
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
