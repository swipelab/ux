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
        case "readFiles": handleReadFiles(result: result)
        case "hasMedia":  handleHasMedia(result: result)
        default:          result(FlutterMethodNotImplemented)
        }
    }

    /// Type-level check mirroring what readImage / readFiles can consume.
    private func handleHasMedia(result: @escaping FlutterResult) {
        let pb = NSPasteboard.general
        if pb.availableType(from: [.png, .tiff]) != nil {
            return result(true)
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        result(pb.canReadObject(forClasses: [NSURL.self], options: options))
    }

    /// File URLs on the pasteboard (Finder "Copy"). Each entry carries a
    /// security-scoped bookmark minted while the pasteboard's transient
    /// sandbox extension is still alive, so Dart-side readers can
    /// re-acquire access later through `ux/file` `beginScopedAccess`.
    private func handleReadFiles(result: @escaping FlutterResult) {
        let pb = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty
        else {
            return result([])
        }
        var out: [[String: Any]] = []
        for url in urls {
            var entry: [String: Any] = [
                "path": url.path,
                "name": url.lastPathComponent,
            ]
            if let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            ) {
                entry["bookmark"] = FlutterStandardTypedData(bytes: bookmark)
            }
            out.append(entry)
        }
        result(out)
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
