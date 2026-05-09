import AppKit
import FlutterMacOS

public class ClipboardPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/clipboard", binaryMessenger: registrar.messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "readImage": handleReadImage(result: result)
        default:          result(FlutterMethodNotImplemented)
        }
    }

    private func handleReadImage(result: @escaping FlutterResult) {
        let pb = NSPasteboard.general

        if let png = pb.data(forType: .png) {
            return result(FlutterStandardTypedData(bytes: png))
        }

        // macOS Screenshot.app and Preview hand off TIFF; transcode so
        // the Dart side always gets PNG bytes regardless of producer.
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return result(FlutterStandardTypedData(bytes: png))
        }

        result(nil)
    }
}
