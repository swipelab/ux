import AVFoundation
import Flutter
import MobileCoreServices
import QuickLook
import UIKit

public class FilePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?
    private var previewDataSource: FilePreviewDataSource?
    private var pickerDelegate: UxDocumentPickerDelegate?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/file", binaryMessenger: registrar.messenger())
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
        // 0 on either axis = preserve aspect ratio at the bound.
        generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: 0)
        // Tolerate a few hundred ms of slop so we can land on a keyframe.
        generator.requestedTimeToleranceBefore = CMTime(value: 500, timescale: 1000)
        generator.requestedTimeToleranceAfter  = CMTime(value: 500, timescale: 1000)

        // Background-thread the decode; method-channel reply marshalls back
        // to the platform thread automatically.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let cgImage = try generator.copyCGImage(
                    at: CMTime(value: Int64(atMs) * 1000, timescale: 1_000_000),
                    actualTime: nil,
                )
                let uiImage = UIImage(cgImage: cgImage)
                guard let png = uiImage.pngData() else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                let reply: [String: Any] = [
                    "png": FlutterStandardTypedData(bytes: png),
                    "width": Int(uiImage.size.width * uiImage.scale),
                    "height": Int(uiImage.size.height * uiImage.scale),
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

    private func handleShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard let topVC = UxWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }

        let url = URL(fileURLWithPath: path)
        let title = args["title"] as? String

        let items: [Any] = title.map { [FileActivityItemSource(url: url, title: $0)] } ?? [url]
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)

        if UIDevice.current.userInterfaceIdiom == .pad,
           let popover = vc.popoverPresentationController {
            popover.sourceView = topVC.view
            if let r = args["sourceRect"] as? [String: Any],
               let x = (r["x"] as? NSNumber)?.doubleValue,
               let y = (r["y"] as? NSNumber)?.doubleValue,
               let w = (r["w"] as? NSNumber)?.doubleValue,
               let h = (r["h"] as? NSNumber)?.doubleValue {
                popover.sourceRect = CGRect(x: x, y: y, width: w, height: h)
            } else {
                let b = topVC.view.bounds
                popover.sourceRect = CGRect(x: b.midX, y: b.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }

        topVC.present(vc, animated: true) {
            result(true)
        }
    }

    private func handlePick(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let topVC = UxWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }
        let args = call.arguments as? [String: Any]
        let mimeTypes = (args?["mimeTypes"] as? [String]) ?? []
        let utis = utiStrings(forMimeTypes: mimeTypes)

        // `.import` mode copies the picked file into the app's Documents/Inbox
        // so the URL is stable after the picker dismisses (matches Android's
        // cache-copy semantics).
        let picker = UIDocumentPickerViewController(documentTypes: utis, in: .import)
        picker.allowsMultipleSelection = false
        let delegate = UxDocumentPickerDelegate(result: result) { [weak self] in
            self?.pickerDelegate = nil
        }
        // The delegate is weak on UIDocumentPickerViewController; keep a strong ref.
        pickerDelegate = delegate
        picker.delegate = delegate

        topVC.present(picker, animated: true, completion: nil)
    }

    /// Maps Dart-side MIME strings (e.g. `image/png`, `image/*`, `*/*`) to
    /// legacy UTI strings. Compatible with iOS 13+ (UTType requires 14+).
    /// Wildcards and unknown MIMEs degrade to `public.data` (the universal
    /// "any data" UTI) so the picker still appears.
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

    private func handleOpen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard let topVC = UxWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }

        let url = URL(fileURLWithPath: path)
        let ds = FilePreviewDataSource(url: url)
        // QLPreviewController requires a strong-retained data source.
        previewDataSource = ds

        let vc = QLPreviewController()
        vc.dataSource = ds

        topVC.present(vc, animated: true) {
            result(true)
        }
    }
}

private final class FilePreviewDataSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as QLPreviewItem
    }
}

/// MIME-type lookup from a filename extension via the legacy UTI machinery
/// (iOS 13 compatible).
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

/// Picker delegate that converts a [UIDocumentPickerViewController] result
/// into the Dart-side reply map. `.import` mode copies the picked file
/// into the app's Documents/Inbox, so the URL is stable.
private final class UxDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let result: FlutterResult
    let onDone: () -> Void
    private var settled = false

    init(result: @escaping FlutterResult, onDone: @escaping () -> Void) {
        self.result = result
        self.onDone = onDone
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !settled else { return }
        settled = true
        defer { onDone() }
        guard let url = urls.first else {
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

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !settled else { return }
        settled = true
        defer { onDone() }
        result(nil)
    }
}

private final class FileActivityItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        title
    }
}
