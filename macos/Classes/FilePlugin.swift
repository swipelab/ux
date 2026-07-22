import AppKit
import AVFoundation
import CoreServices
import FlutterMacOS
import Quartz

public class FilePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    // Active scoped-resource grants keyed by the resolved path. Counter
    // lets nested begin/end pairs nest safely; the URL is the actual
    // access-bearing object so we keep a strong reference until the
    // last release.
    private struct ScopedEntry {
        let url: URL
        var count: Int
    }
    private var scoped: [String: ScopedEntry] = [:]
    private let scopedQueue = DispatchQueue(label: "ux.file.scoped")

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/file", binaryMessenger: registrar.messenger)
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
        case "showInFolder":       handleShowInFolder(call, result: result)
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
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        reply.append([
                            "png": FlutterStandardTypedData(bytes: png),
                            "width": cgImage.width,
                            "height": cgImage.height,
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

    private func handlePick(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let mimeTypes = (args?["mimeTypes"] as? [String]) ?? []

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.canDownloadUbiquitousContents = true
        panel.canResolveUbiquitousConflicts = true
        panel.treatsFilePackagesAsDirectories = false

        let utis = utiStrings(forMimeTypes: mimeTypes)
        // Empty / `public.data` only means "any" — leave allowed types unset
        // so users can pick any file.
        if !(utis.count == 1 && utis[0] == kUTTypeData as String) {
            // `allowedFileTypes` accepts both UTI strings and bare file
            // extensions. Deprecated on macOS 12+ but still functional.
            panel.allowedFileTypes = utis
        }

        let host = XWindow.flutterView?.window
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                result(nil)
                return
            }
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.intValue
            let mime = mimeFromExtension(url.pathExtension)
            let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
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
        guard let view = XWindow.flutterView else {
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

    private func handleShowInFolder(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let bookmarkData = (args["bookmark"] as? FlutterStandardTypedData)?.data
        withScope(path: path, bookmark: bookmarkData) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
                options: .withSecurityScope,
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
                // Already had access — release the duplicate grant we just took.
                url.stopAccessingSecurityScopedResource()
            } else {
                scoped[path] = ScopedEntry(url: url, count: 1)
            }
        }
        var reply: [String: Any] = ["path": path]
        if stale {
            // Caller may want to refresh storage with a new bookmark.
            if let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
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
            guard var entry = scoped[path] else {
                return
            }
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

    /// Resolves [bookmark] (if any) into a security-scoped URL, runs [body],
    /// then releases scope. When [bookmark] is nil falls back to a plain
    /// `URL(fileURLWithPath:)` — used for paths the app can already read
    /// freely (e.g. files inside its own cache).
    private func withScope(path: String, bookmark: Data?, body: (URL) -> Void) {
        guard let bookmark = bookmark else {
            body(URL(fileURLWithPath: path))
            return
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale,
        ) else {
            body(URL(fileURLWithPath: path))
            return
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        body(url)
    }

    private func handleOpen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let bookmarkData = (args["bookmark"] as? FlutterStandardTypedData)?.data

        // Quick Look reads the file lazily — after this method returns — so the
        // security scope must be held for the panel's lifetime, NOT just a
        // synchronous `withScope` span (whose `defer` would release it before
        // the panel ever reads, leaving a sandboxed file blank). Resolve and
        // start scope here, then hand ownership to the responder which releases
        // on deinit (matching the iOS QL handler).
        let (url, scoped) = resolveScoped(path: path, bookmark: bookmarkData)

        // Prefer in-app Quick Look (keeps the host app in the foreground).
        // Fall back to NSWorkspace.open if there's no window to host the panel.
        if let flutterView = XWindow.flutterView,
           let window = flutterView.window,
           let panel = QLPreviewPanel.shared() {
            let responder = XQLPreviewResponder(url: url, window: window, scoped: scoped)
            flutterView.addSubview(responder)
            window.makeFirstResponder(responder)
            panel.updateController()
            panel.makeKeyAndOrderFront(nil)
            result(true)
            return
        }

        // No host window → hand off to the default app. A user-initiated open
        // grants the launched app its own access, so release our scope once the
        // open call returns.
        let opened = NSWorkspace.shared.open(url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        result(opened)
    }

    /// Resolves [path]/[bookmark] to a URL and, for a security-scoped bookmark,
    /// starts access. Returns the URL and whether scope was started — the
    /// caller owns the matching `stopAccessingSecurityScopedResource()`. Unlike
    /// `withScope`, it does NOT auto-release, so the scope can outlive this call
    /// for a lazily-read consumer (the Quick Look panel).
    private func resolveScoped(path: String, bookmark: Data?) -> (URL, Bool) {
        guard let bookmark = bookmark else {
            return (URL(fileURLWithPath: path), false)
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale,
        ) else {
            return (URL(fileURLWithPath: path), false)
        }
        let started = url.startAccessingSecurityScopedResource()
        return (url, started)
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

private final class XQLPreviewResponder: NSView, QLPreviewPanelDataSource {
    let url: URL
    private let scoped: Bool
    private weak var previousFirstResponder: NSResponder?
    private weak var previousWindow: NSWindow?

    init(url: URL, window: NSWindow, scoped: Bool) {
        self.url = url
        self.scoped = scoped
        self.previousWindow = window
        self.previousFirstResponder = window.firstResponder
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // Security scope was started in `handleOpen` and held for the panel's
        // lifetime; release it once the responder (and thus the preview
        // session) is torn down.
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

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
