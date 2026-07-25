#if os(iOS)

import AVFoundation
import Flutter
import MobileCoreServices
import QuickLook
import UIKit

public class FilePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?
    private var previewDataSource: FilePreviewDataSource?
    private var pickerDelegate: XDocumentPickerDelegate?
    private var exportDelegate: XDocumentExportDelegate?

    private struct ScopedEntry {
        let url: URL
        var count: Int
    }
    private var scoped: [String: ScopedEntry] = [:]
    private let scopedQueue = DispatchQueue(label: "ux.file.scoped")

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/file", binaryMessenger: registrar.messenger())
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "share":              handleShare(call, result: result)
        case "open":               handleOpen(call, result: result)
        case "pick":               handlePick(call, result: result)
        case "saveCopy":           handleSaveCopy(call, result: result)
        case "showInFolder":       result(false) // no Finder equivalent on iOS
        case "beginScopedAccess":  handleBeginScopedAccess(call, result: result)
        case "endScopedAccess":    handleEndScopedAccess(call, result: result)
        case "videoThumbnail":     handleVideoThumbnail(call, result: result)
        case "videoThumbnails":    handleVideoThumbnails(call, result: result)
        default:                   result(FlutterMethodNotImplemented)
        }
    }

    private func handleVideoThumbnail(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let atMs = (args["atMs"] as? NSNumber)?.intValue ?? 0
        // nil = native resolution (the frame is a crop-geometry space).
        let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue
        let transform = (args["transform"] as? [NSNumber])?.map { $0.doubleValue }
        let outWidth = (args["outWidth"] as? NSNumber)?.intValue
        let outHeight = (args["outHeight"] as? NSNumber)?.intValue
        let overlayPath = args["overlayPath"] as? String
        let maxLongest = (args["maxLongest"] as? NSNumber)?.intValue
        let bakes = transform?.count == 9 && outWidth != nil && outHeight != nil

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 0 on either axis = preserve aspect ratio at the bound; .zero = no
        // cap. A bake always needs the native-res frame (the affine's
        // coordinate space).
        generator.maximumSize = bakes
            ? .zero
            : maxWidth.map { CGSize(width: CGFloat($0), height: 0) } ?? .zero
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
                if bakes {
                    guard let baked = FilePluginBake.bakeThumb(
                        frame: cgImage, transform: transform!,
                        outWidth: outWidth!, outHeight: outHeight!,
                        overlayPath: overlayPath, maxLongest: maxLongest)
                    else {
                        DispatchQueue.main.async { result(nil) }
                        return
                    }
                    let reply: [String: Any] = [
                        "png": FlutterStandardTypedData(bytes: baked.png),
                        "width": baked.width,
                        "height": baked.height,
                    ]
                    DispatchQueue.main.async { result(reply) }
                    return
                }
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

    /// Batch variant for the video trim scrubber: one native
    /// round-trip for the whole thumbnail strip. Per-frame failures
    /// come back as null entries, in `timestampsMs` order.
    private func handleVideoThumbnails(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let timestampsMs = args["timestampsMs"] as? [NSNumber] else {
            return result(FlutterError(code: "bad_args", message: "path and timestampsMs required", details: nil))
        }
        let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue ?? 128

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: 0)
        generator.requestedTimeToleranceBefore = CMTime(value: 500, timescale: 1000)
        generator.requestedTimeToleranceAfter  = CMTime(value: 500, timescale: 1000)

        DispatchQueue.global(qos: .userInitiated).async {
            var reply: [Any] = []
            for ms in timestampsMs {
                do {
                    let cgImage = try generator.copyCGImage(
                        at: CMTime(value: ms.int64Value * 1000, timescale: 1_000_000),
                        actualTime: nil,
                    )
                    let uiImage = UIImage(cgImage: cgImage)
                    if let png = uiImage.pngData() {
                        reply.append([
                            "png": FlutterStandardTypedData(bytes: png),
                            "width": Int(uiImage.size.width * uiImage.scale),
                            "height": Int(uiImage.size.height * uiImage.scale),
                        ] as [String: Any])
                    } else {
                        reply.append(NSNull())
                    }
                } catch {
                    reply.append(NSNull())
                }
            }
            DispatchQueue.main.async { result(reply) }
        }
    }

    private func handleShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard let topVC = XWindow.topViewController else {
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
        guard let topVC = XWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }
        let args = call.arguments as? [String: Any]
        let mimeTypes = (args?["mimeTypes"] as? [String]) ?? []
        let utis = utiStrings(forMimeTypes: mimeTypes)

        // `.open` returns a security-scoped URL pointing at the user's
        // original file (no Documents/Inbox copy). Persist the bookmark
        // returned to Dart so future opens can re-acquire scope across
        // cold starts.
        let picker = UIDocumentPickerViewController(documentTypes: utis, in: .open)
        picker.allowsMultipleSelection = false
        let delegate = XDocumentPickerDelegate(result: result) { [weak self] in
            self?.pickerDelegate = nil
        }
        // The delegate is weak on UIDocumentPickerViewController; keep a strong ref.
        pickerDelegate = delegate
        picker.delegate = delegate

        topVC.present(picker, animated: true, completion: nil)
    }

    /// Presents the system export picker ("Save to Files") for the file
    /// at `path`. `asCopy` keeps our cache file in place — the picker
    /// writes a copy to wherever the user chooses.
    private func handleSaveCopy(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return result(FlutterError(code: "not_found", message: "no file at path", details: nil))
        }
        guard let topVC = XWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }
        let url = URL(fileURLWithPath: path)
        let picker: UIDocumentPickerViewController
        if #available(iOS 14, *) {
            picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(urls: [url], in: .exportToService)
        }
        let delegate = XDocumentExportDelegate(result: result) { [weak self] in
            self?.exportDelegate = nil
        }
        // The delegate is weak on UIDocumentPickerViewController; keep a strong ref.
        exportDelegate = delegate
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
        guard let topVC = XWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }

        let bookmarkData = (args["bookmark"] as? FlutterStandardTypedData)?.data
        let resolved = resolveURL(path: path, bookmark: bookmarkData)
        let url = resolved.url
        let started = resolved.scoped
        // QuickLook keeps the URL alive while presented; we hold scope for
        // the controller's lifetime by deferring stop until dismiss.
        let ds = FilePreviewDataSource(url: url) {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        previewDataSource = ds

        let vc = QLPreviewController()
        vc.dataSource = ds

        topVC.present(vc, animated: true) {
            result(true)
        }
    }

    private func handleBeginScopedAccess(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let bookmarkData = (args["bookmark"] as? FlutterStandardTypedData)?.data else {
            return result(FlutterError(code: "bad_args", message: "bookmark is required", details: nil))
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale,
            )
        } catch {
            return result(FlutterError(code: "stale_bookmark",
                message: "could not resolve bookmark: \(error.localizedDescription)",
                details: nil))
        }
        guard url.startAccessingSecurityScopedResource() else {
            return result(FlutterError(code: "access_denied",
                message: "startAccessingSecurityScopedResource failed",
                details: nil))
        }
        let path = url.path
        scopedQueue.sync {
            if var entry = scoped[path] {
                entry.count += 1
                scoped[path] = entry
                url.stopAccessingSecurityScopedResource()
            } else {
                scoped[path] = ScopedEntry(url: url, count: 1)
            }
        }
        var reply: [String: Any] = ["path": path]
        if stale {
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            ) {
                reply["bookmark"] = FlutterStandardTypedData(bytes: refreshed)
            }
        }
        result(reply)
    }

    private func handleEndScopedAccess(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        scopedQueue.sync {
            guard var entry = scoped[path] else { return }
            entry.count -= 1
            if entry.count <= 0 {
                entry.url.stopAccessingSecurityScopedResource()
                scoped.removeValue(forKey: path)
            } else {
                scoped[path] = entry
            }
        }
        result(nil)
    }

    /// Resolves [bookmark] (when present) into a security-scoped URL and
    /// starts access. Falls back to a plain `URL(fileURLWithPath:)` when no
    /// bookmark is provided or resolution fails.
    private func resolveURL(path: String, bookmark: Data?) -> (url: URL, scoped: Bool) {
        guard let bookmark = bookmark else {
            return (URL(fileURLWithPath: path), false)
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale,
        ) else {
            return (URL(fileURLWithPath: path), false)
        }
        let started = url.startAccessingSecurityScopedResource()
        return (url, started)
    }
}

private final class FilePreviewDataSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    let onDeinit: (() -> Void)?
    init(url: URL, onDeinit: (() -> Void)? = nil) {
        self.url = url
        self.onDeinit = onDeinit
    }
    deinit { onDeinit?() }

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

/// Picker delegate for `.open` mode. The returned URL is security-scoped;
/// we briefly start access to read attributes + create a bookmark, then
/// stop access. Persisted bookmark lets Dart re-acquire scope later via
/// `beginScopedAccess`.
private final class XDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
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
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        let path = url.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue
        let mime = mimeFromExtension(url.pathExtension)
        // iOS bookmarks don't take `.withSecurityScope` (that's macOS-only);
        // bookmarks created from a security-scoped URL stay scoped.
        let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
        var reply: [String: Any] = [
            "path": path,
            "name": url.lastPathComponent,
            "mimeType": mime as Any,
            "size": size as Any,
        ]
        if let bookmark = bookmark {
            reply["bookmark"] = FlutterStandardTypedData(bytes: bookmark)
        }
        result(reply)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !settled else { return }
        settled = true
        defer { onDone() }
        result(nil)
    }
}

/// Picker delegate for export mode (`saveCopy`). The system writes the
/// copy itself — we only report whether the user completed or dismissed.
private final class XDocumentExportDelegate: NSObject, UIDocumentPickerDelegate {
    private let result: FlutterResult
    private let onDone: () -> Void
    private var settled = false

    init(result: @escaping FlutterResult, onDone: @escaping () -> Void) {
        self.result = result
        self.onDone = onDone
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !settled else { return }
        settled = true
        defer { onDone() }
        result("saved")
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !settled else { return }
        settled = true
        defer { onDone() }
        result("cancelled")
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

#endif
