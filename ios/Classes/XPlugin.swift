import Flutter
import UIKit

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
            UxVideoPlayerPlugin(),
            UrlPlugin(),
        ]
        for plugin in plugins {
            plugin.register(with: registrar)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(FlutterMethodNotImplemented)
    }
}
