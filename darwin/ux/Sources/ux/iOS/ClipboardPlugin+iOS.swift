#if os(iOS)

import Flutter
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

public class ClipboardPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/clipboard", binaryMessenger: registrar.messenger())
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "readImage": handleReadImage(result: result)
        case "hasMedia":  result(UIPasteboard.general.hasImages)
        default:          result(FlutterMethodNotImplemented)
        }
    }

    private func handleReadImage(result: @escaping FlutterResult) {
        let pb = UIPasteboard.general

        // Prefer raw PNG / JPEG bytes already on the clipboard so we don't
        // round-trip through UIImage when we don't have to.
        if #available(iOS 14.0, *) {
            if let png = pb.data(forPasteboardType: UTType.png.identifier) {
                return result(FlutterStandardTypedData(bytes: png))
            }
            if let jpg = pb.data(forPasteboardType: UTType.jpeg.identifier) {
                return result(FlutterStandardTypedData(bytes: jpg))
            }
        } else {
            if let png = pb.data(forPasteboardType: kUTTypePNG as String) {
                return result(FlutterStandardTypedData(bytes: png))
            }
            if let jpg = pb.data(forPasteboardType: kUTTypeJPEG as String) {
                return result(FlutterStandardTypedData(bytes: jpg))
            }
        }

        // Fallback: re-encode whatever UIImage resolves to as PNG.
        if let img = pb.image, let png = img.pngData() {
            return result(FlutterStandardTypedData(bytes: png))
        }

        result(nil)
    }
}

#endif
