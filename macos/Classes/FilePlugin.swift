import AppKit
import AVFoundation
import CoreServices
import FlutterMacOS
import Quartz

public class FilePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/file", binaryMessenger: registrar.messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "share":          handleShare(call, result: result)
        case "open":           handleOpen(call, result: result)
        case "pick":           handlePick(call, result: result)
        case "videoThumbnail": handleVideoThumbnail(call, result: result)
        default:               result(FlutterMethodNotImplemented)
        }
    }

    private func handleVideoThumbnail(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let atMs = (args["atMs"] as? NSNumber)?.intValue ?? 0
        let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue ?? 320

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: 0)
        generator.requestedTimeToleranceBefore = CMTime(value: 500, timescale: 1000)
        generator.requestedTimeToleranceAfter  = CMTime(value: 500, timescale: 1000)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let cgImage = try generator.copyCGImage(
                    at: CMTime(value: Int64(atMs) * 1000, timescale: 1_000_000),
                    actualTime: nil,
                )
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let reply: [String: Any] = [
                    "png": FlutterStandardTypedData(bytes: png),
                    "width": cgImage.width,
                    "height": cgImage.height,
                ]
                DispatchQueue.main.async { result(reply) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "decode_failed",
                        message: "could not extract frame: \(error.localizedDescription)",
                        details: nil,
                    ))
                }
            }
        }
    }

    private func handlePick(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let mimeTypes = (args?["mimeTypes"] as? [String]) ?? []

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        let utis = utiStrings(forMimeTypes: mimeTypes)
        // Empty / `public.data` only means "any" — leave allowed types unset
        // so users can pick any file.
        if !(utis.count == 1 && utis[0] == kUTTypeData as String) {
            // `allowedFileTypes` accepts both UTI strings and bare file
            // extensions. Deprecated on macOS 12+ but still functional.
            panel.allowedFileTypes = utis
        }

        let host = UxWindow.flutterView?.window
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                result(nil)
                return
            }
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.intValue
            let mime = mimeFromExtension(url.pathExtension)
            result([
                "path": path,
                "name": url.lastPathComponent,
                "mimeType": mime as Any,
                "size": size as Any,
            ])
        }

        if let host = host {
            panel.beginSheetModal(for: host, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Maps Dart-side MIME strings to legacy UTI strings (CoreServices,
    /// macOS 10.15-compatible). Wildcards and unknown MIMEs degrade to
    /// `public.data`.
    private func utiStrings(forMimeTypes mimes: [String]) -> [String] {
        if mimes.isEmpty { return [kUTTypeData as String] }
        var out: [String] = []
        for m in mimes {
            if m == "*/*" { return [kUTTypeData as String] }
            if m.hasSuffix("/*") {
                switch String(m.dropLast(2)) {
                case "image":       out.append(kUTTypeImage as String)
                case "video":       out.append(kUTTypeMovie as String)
                case "audio":       out.append(kUTTypeAudio as String)
                case "text":        out.append(kUTTypeText as String)
                case "application": out.append(kUTTypeData as String)
                default:            out.append(kUTTypeData as String)
                }
                continue
            }
            if let unmanaged = UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassMIMEType, m as CFString, nil
            ) {
                out.append(unmanaged.takeRetainedValue() as String)
            }
        }
        return out.isEmpty ? [kUTTypeData as String] : out
    }

    private func handleShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard let view = UxWindow.flutterView else {
            return result(FlutterError(code: "no_view", message: "no Flutter view", details: nil))
        }

        let url = URL(fileURLWithPath: path)
        let picker = NSSharingServicePicker(items: [url])

        let rect: NSRect
        if let r = args["sourceRect"] as? [String: Any],
           let x = (r["x"] as? NSNumber)?.doubleValue,
           let y = (r["y"] as? NSNumber)?.doubleValue,
           let w = (r["w"] as? NSNumber)?.doubleValue,
           let h = (r["h"] as? NSNumber)?.doubleValue {
            if view.isFlipped {
                rect = NSRect(x: x, y: y, width: w, height: h)
            } else {
                rect = NSRect(x: x, y: view.bounds.height - y - h, width: w, height: h)
            }
        } else {
            rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }

        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        result(true)
    }

    private func handleOpen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let url = URL(fileURLWithPath: path)

        // Prefer in-app Quick Look (keeps Banlu in the foreground).
        // Fall back to NSWorkspace.open if there's no window to host the panel.
        if let flutterView = UxWindow.flutterView,
           let window = flutterView.window,
           let panel = QLPreviewPanel.shared() {
            let responder = UxQLPreviewResponder(url: url, window: window)
            flutterView.addSubview(responder)
            window.makeFirstResponder(responder)
            panel.updateController()
            panel.makeKeyAndOrderFront(nil)
            result(true)
            return
        }

        result(NSWorkspace.shared.open(url))
    }
}

/// MIME-type lookup from a filename extension via the legacy UTI machinery
/// (macOS 10.15 compatible).
fileprivate func mimeFromExtension(_ ext: String) -> String? {
    guard !ext.isEmpty else { return nil }
    guard let uti = UTTypeCreatePreferredIdentifierForTag(
        kUTTagClassFilenameExtension, ext as CFString, nil
    )?.takeRetainedValue() else { return nil }
    guard let mime = UTTypeCopyPreferredTagWithClass(
        uti, kUTTagClassMIMEType
    )?.takeRetainedValue() else { return nil }
    return mime as String
}

private final class UxQLPreviewResponder: NSView, QLPreviewPanelDataSource {
    let url: URL
    private weak var previousFirstResponder: NSResponder?
    private weak var previousWindow: NSWindow?

    init(url: URL, window: NSWindow) {
        self.url = url
        self.previousWindow = window
        self.previousFirstResponder = window.firstResponder
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        let win = previousWindow
        let prev = previousFirstResponder
        DispatchQueue.main.async { [weak self] in
            win?.makeFirstResponder(prev)
            self?.removeFromSuperview()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as QLPreviewItem
    }
}
