import AppKit
import FlutterMacOS
import ZIPFoundation

/// `ux/drop/events` — OS file drag-and-drop for desktop.
///
/// Installs a transparent overlay `NSView` over the Flutter view, registered
/// as a dragging destination, and forwards the drag lifecycle (`enter` /
/// `update` / `exit` / `drop`) to Dart. Dropped items carry the file path, the
/// basename, a security-scoped bookmark — resolved later through the existing
/// `ux/file` `beginScopedAccess`, exactly like the picker — plus
/// `isTemporaryCopy` (the OS wrote an app-owned temp copy for a promised file,
/// so the upload must promote it into the managed cache rather than reference
/// the soon-purged temp) and `isDirectory` (folders / macOS packages can't be
/// uploaded as a single file).
///
/// Lifecycle: the overlay is installed lazily on first `onListen` (Dart only
/// subscribes when a drop region mounts — never on mobile). It is parented to
/// the registrar's Flutter view (falling back to the key window's), retained
/// by its superview and referenced weakly here, and removed on `onCancel` —
/// no retain cycle, no duplicate on re-listen, nothing left behind.
///
/// Dart deliberately never cancels the event subscription (cancelling on the
/// last region detach would lose an in-flight drop and thrash listen/cancel
/// during list scroll), so the overlay stays installed after regions detach.
/// To avoid claiming a copy when nothing can accept the drop, Dart pushes its
/// active-region state over the `ux/drop` method channel (`setHasRegions`);
/// while no region is active the overlay reports `.none` for enter/update. The
/// same channel zips dropped folders (`zipDirectory` → ZIPFoundation), streams
/// determinate progress back (`zipProgress`), and cancels (`cancelZip`).
public class DropPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private var eventChannel: FlutterEventChannel?
    private var methodChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?
    private weak var registrar: FlutterPluginRegistrar?
    private weak var overlay: DropOverlayView?
    private var installAttempts = 0
    /// Whether any Dart drop region is currently able to accept a drop. Driven
    /// by `setHasRegions` and mirrored onto the overlay; kept here too so a
    /// (re)installed overlay picks up the latest value.
    private var hasActiveRegions = true

    /// In-flight folder-zip jobs, keyed by the Dart-supplied jobId. Holds each
    /// `Progress` (so `cancelZip` can cancel it) and its `fractionCompleted`
    /// observation. Touched only on the main thread.
    private final class ZipJob {
        let progress: Progress
        var observation: NSKeyValueObservation?
        var lastEmitted: Double = -1
        init(_ progress: Progress) { self.progress = progress }
    }
    private var zipJobs: [String: ZipJob] = [:]

    public func register(with registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        let events = FlutterEventChannel(
            name: "ux/drop/events",
            binaryMessenger: registrar.messenger,
        )
        events.setStreamHandler(self)
        eventChannel = events

        // Dart → native control channel: carries active-region state so the
        // overlay can report `.none` when no region can accept a drop.
        let methods = FlutterMethodChannel(
            name: "ux/drop",
            binaryMessenger: registrar.messenger,
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = methods
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setHasRegions":
            let value = (call.arguments as? Bool) ?? true
            hasActiveRegions = value
            overlay?.hasActiveRegions = value
            result(nil)
        case "zipDirectory":
            guard let args = call.arguments as? [String: Any?],
                  let jobId = args["jobId"] as? String,
                  let path = args["path"] as? String else {
                result(FlutterError(
                    code: "bad_args",
                    message: "zipDirectory requires jobId and path", details: nil))
                return
            }
            let bookmark = (args["bookmark"] as? FlutterStandardTypedData)?.data
            startZip(jobId: jobId, path: path, bookmark: bookmark, result: result)
        case "cancelZip":
            if let jobId = call.arguments as? String {
                zipJobs[jobId]?.progress.cancel()
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private enum ZipError: Error { case notAFile }

    /// Register a cancellable, progress-reporting folder-zip job and run it off
    /// the main thread (a large folder can take a while). Progress is streamed
    /// back as `zipProgress` (throttled to ~0.5% steps); the result is the zip
    /// URL, or a `cancelled` / `zip_failed` `FlutterError`.
    private func startZip(
        jobId: String, path: String, bookmark: Data?,
        result: @escaping FlutterResult
    ) {
        let progress = Progress()
        let job = ZipJob(progress)
        job.observation = progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] prog, _ in
            let fraction = prog.fractionCompleted
            DispatchQueue.main.async {
                guard let self = self, let job = self.zipJobs[jobId] else { return }
                // Throttle: only forward ~0.5% steps (and always the final 1.0).
                if fraction < 1.0,
                   (fraction * 200).rounded(.down) <= (job.lastEmitted * 200).rounded(.down) {
                    return
                }
                job.lastEmitted = fraction
                self.methodChannel?.invokeMethod(
                    "zipProgress", arguments: ["jobId": jobId, "fraction": fraction])
            }
        }
        zipJobs[jobId] = job

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zip = try Self.zipForUpload(
                    path: path, bookmark: bookmark, progress: progress)
                DispatchQueue.main.async {
                    self.clearZipJob(jobId)
                    // A cancel can land after the last byte is written but before
                    // we return — `zipItem` then doesn't throw. Honor it: discard
                    // the just-written zip and report cancellation, so "cancel
                    // sends nothing" holds even at the finish line.
                    if progress.isCancelled {
                        try? FileManager.default.removeItem(
                            at: zip.deletingLastPathComponent())
                        result(FlutterError(
                            code: "cancelled", message: "cancelled", details: nil))
                        return
                    }
                    result(["path": zip.path, "name": zip.lastPathComponent])
                }
            } catch {
                DispatchQueue.main.async {
                    let cancelled = progress.isCancelled
                    self.clearZipJob(jobId)
                    result(FlutterError(
                        code: cancelled ? "cancelled" : "zip_failed",
                        message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func clearZipJob(_ jobId: String) {
        zipJobs[jobId]?.observation?.invalidate()
        zipJobs[jobId] = nil
    }

    /// Compress the directory / package at [path] into a single `.zip` under
    /// `ux_drops` and return its URL. Uses ZIPFoundation's
    /// `FileManager.zipItem(…, progress:)`, which reports a determinate fraction
    /// into [progress] and aborts (throwing) when [progress] is cancelled.
    /// `shouldKeepParent: true` keeps the dropped folder's name as the zip's
    /// root entry. Access is re-acquired from the drop's security-scoped
    /// [bookmark] (the original drag grant is gone by the time Dart asks),
    /// falling back to the raw path.
    private static func zipForUpload(
        path: String, bookmark: Data?, progress: Progress
    ) throws -> URL {
        var srcURL = URL(fileURLWithPath: path)
        var scoped = false
        if let bookmark = bookmark {
            var stale = false
            // Only adopt the resolved bookmark when it's NOT stale — a stale
            // bookmark may resolve to a URL whose scope no longer applies, which
            // would fail the zip and surface a spurious "couldn't compress". When
            // stale, fall back to the raw path (the live drag grant may cover it).
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale {
                srcURL = resolved
                scoped = resolved.startAccessingSecurityScopedResource()
            }
        }
        defer { if scoped { srcURL.stopAccessingSecurityScopedResource() } }

        let destDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux_drops")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = destDir.appendingPathComponent("\(srcURL.lastPathComponent).zip")

        // On any failure (incl. cancellation), remove the whole per-drop subdir
        // so a botched/aborted zip leaves nothing behind; on success `dest`
        // lives inside it and is later moved into the cache by the promotion.
        do {
            try FileManager.default.createDirectory(
                at: destDir, withIntermediateDirectories: true)
            try FileManager.default.zipItem(
                at: srcURL, to: dest,
                shouldKeepParent: true,
                compressionMethod: .deflate,
                progress: progress)
            // Guard the contract: never hand Dart a directory it can't upload.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir),
                  !isDir.boolValue else {
                throw ZipError.notAFile
            }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: destDir)
            throw error
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        // A subscription means at least one region just mounted; the empty/
        // non-empty transitions thereafter arrive via `setHasRegions`.
        hasActiveRegions = true
        installAttempts = 0
        installIfNeeded()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        overlay?.removeFromSuperview()
        overlay = nil
        return nil
    }

    // MARK: - Overlay

    /// The view to host the overlay: the registrar's own Flutter view when
    /// available (the exact view this plugin was registered for), else the key
    /// window's content view.
    private var hostView: NSView? { registrar?.view ?? XWindow.flutterView }

    /// Adds the drag-destination overlay to the host Flutter view. Idempotent:
    /// no-ops when already installed on the live container, and re-homes it if
    /// the container changed (window swap). Retries on the main runloop
    /// (bounded) while the view isn't ready yet.
    private func installIfNeeded() {
        guard let container = hostView else {
            guard installAttempts < 60 else { return }
            installAttempts += 1
            DispatchQueue.main.async { [weak self] in self?.installIfNeeded() }
            return
        }
        if let overlay = overlay, overlay.superview === container { return }
        overlay?.removeFromSuperview()

        let view = DropOverlayView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.hasActiveRegions = hasActiveRegions
        view.onEvent = { [weak self] event in self?.eventSink?(event) }
        view.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        )
        view.registerForDraggedTypes([.fileURL])
        container.addSubview(view)
        overlay = view
    }
}

/// Transparent dragging-destination overlay covering the Flutter view.
///
/// Mouse pass-through is NOT a consequence of skipping a `hitTest` override:
/// AppKit's default `hitTest(_:)` returns this overlay (the front-most view)
/// for points inside its bounds, so the overlay — not the Flutter view — is the
/// hit view. Clicks still reach Flutter because the overlay implements no mouse
/// handlers and `NSResponder`'s default forwards an unhandled mouse event to the
/// next responder, which for a view is its superview — here the Flutter view.
/// (If a future change needs true geometric pass-through — e.g. correct
/// cursor-rect / hover behaviour, which the responder chain does not cover —
/// override `hitTest` to return nil; drag routing is unaffected, since
/// destinations resolve by registered types, not `hitTest`.) Mirrors the proven
/// `desktop_drop` overlay shape.
final class DropOverlayView: NSView {
    var onEvent: (([String: Any?]) -> Void)?

    /// Whether any Dart drop region can currently accept a drop. When false the
    /// overlay reports `.none` so the OS shows no copy affordance — the overlay
    /// stays installed (Dart never cancels the subscription) but goes inert.
    var hasActiveRegions = true

    /// Root for accepted file promises (drags from sources that vend promised
    /// files rather than concrete URLs, e.g. Photos). Each promised item is
    /// received into a *unique* subdir of this root (see `performDragOperation`)
    /// so two same-named promises never collide; the temp is moved out by the
    /// app's post-upload cache promotion and any abandoned copy is reaped with
    /// the OS temp dir.
    private lazy var promiseDir: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux_drops")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        // Serialize promise completions: keeps item order deterministic and,
        // with the lock below, the results array race-free.
        q.maxConcurrentOperationCount = 1
        return q
    }()

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // No region can accept right now → claim nothing (no copy cursor).
        guard hasActiveRegions else { return [] }
        emitPoint("enter", sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasActiveRegions else { return [] }
        emitPoint("update", sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onEvent?(["type": "exit"])
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = flutterPoint(sender.draggingLocation)
        var items: [[String: Any?]] = []
        let itemsLock = NSLock()
        // Appended from both the main thread (URL branch) and the promise
        // completion queue — guard every mutation.
        func append(_ item: [String: Any?]) {
            itemsLock.lock()
            items.append(item)
            itemsLock.unlock()
        }

        let group = DispatchGroup()
        let searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        sender.enumerateDraggingItems(
            options: [], for: nil,
            classes: [NSFilePromiseReceiver.self, NSURL.self],
            searchOptions: searchOptions
        ) { draggingItem, _, _ in
            switch draggingItem.item {
            case let receiver as NSFilePromiseReceiver:
                // Unique per-item destination so same-name promised files from
                // one drop (or across drops) never overwrite each other; the
                // display name (`lastPathComponent`) is preserved inside it.
                let dest = self.promiseDir.appendingPathComponent(
                    UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: dest, withIntermediateDirectories: true)
                group.enter()
                receiver.receivePromisedFiles(
                    atDestination: dest, options: [:],
                    operationQueue: self.promiseQueue
                ) { fileURL, error in
                    // Promised files are OS-written app-owned temp copies →
                    // isTemporaryCopy: true (promote into cache after upload).
                    if error == nil { append(Self.describe(fileURL, fromPromise: true)) }
                    group.leave()
                }
            case let fileURL as URL:
                // A durable user-chosen path → isTemporaryCopy: false.
                append(Self.describe(fileURL, fromPromise: false))
            default:
                break
            }
        }

        // Capture the sink strongly: promise receives are async, and if the
        // overlay is torn down before they finish, a `[weak self]` here would
        // silently drop the completed drop. The sink itself only weakly holds
        // the plugin, so there's no retain cycle.
        let emit = onEvent
        group.notify(queue: .main) {
            emit?([
                "type": "drop",
                "x": p.x, "y": p.y,
                "items": items,
            ])
        }
        return true
    }

    private static func describe(_ url: URL, fromPromise: Bool) -> [String: Any?] {
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        var m: [String: Any?] = [
            "path": url.path,
            "name": url.lastPathComponent,
            "isTemporaryCopy": fromPromise,
            "isDirectory": isDirectory,
        ]
        if let bookmark = bookmark {
            m["bookmark"] = FlutterStandardTypedData(bytes: bookmark)
        }
        return m
    }

    private func emitPoint(_ type: String, _ sender: NSDraggingInfo) {
        let p = flutterPoint(sender.draggingLocation)
        onEvent?(["type": type, "x": p.x, "y": p.y])
    }

    /// Window drag location → Flutter global logical coords (top-left origin).
    /// `convert(_:from: nil)` maps window-base → this view (handling the
    /// title-bar offset); the Y flip converts AppKit's bottom-left origin.
    /// On macOS points equal Flutter logical pixels, so no DPR scaling.
    private func flutterPoint(_ windowLocation: NSPoint) -> CGPoint {
        let local = convert(windowLocation, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }
}
