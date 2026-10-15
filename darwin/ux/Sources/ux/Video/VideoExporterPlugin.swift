import AVFoundation
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// `ux/video/export` (+`/events`) — trim / mute / crop-rotate-flip export.
///
/// A trim/mute-only request composes an `AVMutableComposition` and runs
/// it through `AVAssetExportSession` with the passthrough preset (a
/// lossless remux, no re-encode). A request carrying a `transform`
/// switches to a re-encode: an `AVAssetReader` feeds an
/// `AVMutableVideoComposition` (per-frame affine into the output canvas)
/// to an `AVAssetWriter` at the caller's target bitrate, so the output
/// bakes the caller's on-screen crop exactly. Progress is streamed
/// per-session; cancel aborts and deletes the partial output.
public class UxVideoExporterPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var sessions: [Int: ExportTask] = [:]

    public func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "ux/video/export",
            binaryMessenger: messenger(registrar)
        )
        methods.setMethodCallHandler(handle)

        let events = FlutterEventChannel(
            name: "ux/video/export/events",
            binaryMessenger: messenger(registrar)
        )
        events.setStreamHandler(self)
    }

    private func messenger(_ registrar: FlutterPluginRegistrar) -> FlutterBinaryMessenger {
        #if os(iOS)
        return registrar.messenger()
        #elseif os(macOS)
        return registrar.messenger
        #endif
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start": start(call, result: result)
        case "cancel": cancel(call, result: result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func emit(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }

    /// Ends [task]'s session on the main queue with [event], unless a cancel
    /// reached [task] first, which ends it as cancelled and deletes its output.
    private func finish(_ sessionId: Int, _ task: ExportTask, _ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            task.progressTimer?.cancel()
            self.sessions[sessionId] = nil
            if task.cancelled {
                try? FileManager.default.removeItem(atPath: task.outPath)
                self.eventSink?(Self.errorEvent(sessionId, "cancelled", "export cancelled"))
            } else {
                self.eventSink?(event)
            }
        }
    }

    private func fail(_ sessionId: Int, _ task: ExportTask, _ code: String, _ message: String) {
        finish(sessionId, task, Self.errorEvent(sessionId, code, message))
    }

    private static func errorEvent(_ sessionId: Int, _ code: String, _ message: String) -> [String: Any] {
        ["sessionId": sessionId, "type": "error", "code": code, "message": message]
    }

    private func start(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = (args["sessionId"] as? NSNumber)?.intValue,
              let path = args["path"] as? String,
              let outPath = args["outPath"] as? String else {
            return result(FlutterError(code: "bad_args", message: "sessionId, path, outPath required", details: nil))
        }
        let trimStartMs = (args["trimStartMs"] as? NSNumber)?.int64Value
        let trimEndMs = (args["trimEndMs"] as? NSNumber)?.int64Value
        let removeAudio = (args["removeAudio"] as? NSNumber)?.boolValue ?? false
        let transform = (args["transform"] as? [NSNumber])?.map { $0.doubleValue }
        let outWidth = (args["outWidth"] as? NSNumber)?.intValue
        let outHeight = (args["outHeight"] as? NSNumber)?.intValue
        let videoBitrate = (args["videoBitrate"] as? NSNumber)?.intValue
        let overlayPath = args["overlayPath"] as? String

        let task = ExportTask(outPath: outPath)
        sessions[sessionId] = task
        result(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                return self.fail(sessionId, task, "no_video_track", "no video track in \(path)")
            }

            let fullDuration = asset.duration
            let startTime = trimStartMs.map { CMTime(value: $0, timescale: 1000) } ?? .zero
            let endTime = trimEndMs.map { CMTime(value: $0, timescale: 1000) } ?? fullDuration
            let range = CMTimeRange(start: startTime, end: CMTimeMinimum(endTime, fullDuration))
            guard range.duration.seconds > 0 else {
                return self.fail(sessionId, task, "bad_trim", "empty trim range")
            }

            // 0-based composition: the trimmed range inserted at .zero so
            // the output starts at time 0 (both paths). Audio omitted when muted.
            let composition = AVMutableComposition()
            let compVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            do {
                try compVideo?.insertTimeRange(range, of: videoTrack, at: .zero)
                if !removeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
                    let compAudio = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try compAudio?.insertTimeRange(range, of: audioTrack, at: .zero)
                }
            } catch {
                return self.fail(sessionId, task, "compose_failed", error.localizedDescription)
            }

            let durationMs = Int((range.duration.seconds * 1000).rounded())

            if let transform, transform.count == 9,
               let outWidth, let outHeight, let compVideo {
                self.exportTransformed(
                    sessionId: sessionId, task: task, composition: composition,
                    compVideo: compVideo, sourceTransform: Self.uprightTransform(of: videoTrack),
                    affine: transform, outWidth: outWidth, outHeight: outHeight,
                    videoBitrate: videoBitrate ?? 3_000_000, hasAudio: !removeAudio,
                    overlayPath: overlayPath,
                    outPath: outPath, durationMs: durationMs)
            } else {
                compVideo?.preferredTransform = videoTrack.preferredTransform
                self.exportPassthrough(
                    sessionId: sessionId, task: task, composition: composition,
                    videoTrack: videoTrack, outPath: outPath, durationMs: durationMs)
            }
        }
    }

    // MARK: - Passthrough (trim / mute) — lossless remux

    private func exportPassthrough(
        sessionId: Int, task: ExportTask, composition: AVMutableComposition,
        videoTrack: AVAssetTrack, outPath: String, durationMs: Int
    ) {
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough
        ) else {
            return fail(sessionId, task, "session_failed", "could not create export session")
        }

        let outUrl = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outUrl)
        session.outputURL = outUrl
        session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov

        let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let outWidth = Int(abs(natural.width).rounded())
        let outHeight = Int(abs(natural.height).rounded())

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self, weak session] in
            guard let session else { return }
            self?.emit(["sessionId": sessionId, "type": "progress", "value": Double(session.progress)])
        }
        timer.resume()

        // exportAsynchronously raises after a cancelExport, so the abort attaches after it.
        DispatchQueue.main.async {
            task.progressTimer = timer
            session.exportAsynchronously { [weak self] in
                guard let self else { return }
                switch session.status {
                case .completed:
                    self.finish(sessionId, task, [
                        "sessionId": sessionId, "type": "done", "path": outPath,
                        "width": outWidth, "height": outHeight, "durationMs": durationMs,
                    ])
                case .cancelled:
                    try? FileManager.default.removeItem(at: outUrl)
                    self.fail(sessionId, task, "cancelled", "export cancelled")
                default:
                    try? FileManager.default.removeItem(at: outUrl)
                    self.fail(sessionId, task, "export_failed", session.error?.localizedDescription ?? "unknown")
                }
            }
            task.attach { session.cancelExport() }
        }
    }

    // MARK: - Transform (crop / rotate / flip) — re-encode

    private func exportTransformed(
        sessionId: Int, task: ExportTask, composition: AVMutableComposition,
        compVideo: AVMutableCompositionTrack, sourceTransform: CGAffineTransform,
        affine: [Double], outWidth: Int, outHeight: Int, videoBitrate: Int,
        hasAudio: Bool, overlayPath: String?, outPath: String, durationMs: Int
    ) {
        let outUrl = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outUrl)

        // Flutter sends a row-major 3×3 source-px → output-px affine
        // [a,b,tx, d,e,ty, …]. CG's convention is the transpose. The
        // Flutter affine is in upright (decoded-poster) space, so compose
        // the track's origin-anchored upright transform first:
        // raw → upright@origin → output.
        let flutter = CGAffineTransform(
            a: affine[0], b: affine[3], c: affine[1], d: affine[4], tx: affine[2], ty: affine[5])
        let full = sourceTransform.concatenating(flutter)

        // Paint-strokes overlay: a transparent PNG in upright source px.
        // Pre-render it ONCE through the (upright-space) Flutter affine
        // into the output canvas; the reading loop then just alpha-blends
        // it over each already-transformed frame.
        let overlayOut: CGImage? = overlayPath.flatMap { path in
            Self.renderOverlay(path: path, affine: flutter,
                               outWidth: outWidth, outHeight: outHeight)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: outWidth, height: outHeight)
        let fps = compVideo.nominalFrameRate > 0 ? compVideo.nominalFrameRate : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layer.setTransform(full, at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: composition)
            writer = try AVAssetWriter(url: outUrl, fileType: .mp4)
        } catch {
            return fail(sessionId, task, "session_failed", error.localizedDescription)
        }

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = videoComposition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            return fail(sessionId, task, "session_failed", "reader rejects video output")
        }
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        if hasAudio, let audioTrack = composition.tracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOut = out }
        }

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else {
            return fail(sessionId, task, "session_failed", "writer rejects video input")
        }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        guard reader.startReading(), writer.startWriting() else {
            try? FileManager.default.removeItem(at: outUrl)
            return fail(sessionId, task, "session_failed",
                        reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(composition.duration.seconds, 0.001)
        let group = DispatchGroup()
        var pumps = [SamplePump(
            output: videoOut, input: videoIn,
            queue: DispatchQueue(label: "ux.video.export.video.\(sessionId)"), group: group
        ) { buffer in
            if let overlayOut,
               let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
                Self.blend(overlayOut, onto: pixelBuffer)
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            self.emit(["sessionId": sessionId, "type": "progress",
                       "value": min(pts / totalSeconds, 1.0)])
        }]
        if let audioOut, let audioIn {
            pumps.append(SamplePump(
                output: audioOut, input: audioIn,
                queue: DispatchQueue(label: "ux.video.export.audio.\(sessionId)"), group: group))
        }
        pumps.forEach { $0.start() }

        DispatchQueue.main.async {
            task.attach { [pumps] in
                pumps.forEach { $0.cancel() }
                reader.cancelReading()
                writer.cancelWriting()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if writer.status == .cancelled {
                try? FileManager.default.removeItem(at: outUrl)
                return self.fail(sessionId, task, "cancelled", "export cancelled")
            }
            if reader.status == .failed {
                try? FileManager.default.removeItem(at: outUrl)
                return self.fail(sessionId, task, "export_failed", reader.error?.localizedDescription ?? "read failed")
            }
            writer.finishWriting {
                if writer.status == .completed {
                    self.finish(sessionId, task, [
                        "sessionId": sessionId, "type": "done", "path": outPath,
                        "width": outWidth, "height": outHeight, "durationMs": durationMs,
                    ])
                } else {
                    try? FileManager.default.removeItem(at: outUrl)
                    self.fail(sessionId, task, "export_failed",
                              writer.error?.localizedDescription ?? "write failed")
                }
            }
        }
    }

    /// The track's raw→upright transform with the upright frame anchored
    /// at the origin. Camera tracks store the bare rotation/flip
    /// (tx/ty = 0), which alone would land the frame outside the render
    /// canvas.
    private static func uprightTransform(of track: AVAssetTrack) -> CGAffineTransform {
        let t = track.preferredTransform
        let rect = CGRect(origin: .zero, size: track.naturalSize).applying(t)
        return t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private func cancel(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = (args["sessionId"] as? NSNumber)?.intValue else {
            return result(FlutterError(code: "bad_args", message: "sessionId required", details: nil))
        }
        sessions[sessionId]?.cancel()
        result(nil)
    }

    /// Rasterise the source-space overlay PNG through the upright→output
    /// [affine] into an output-sized RGBA image. The CG flips convert
    /// between the affine's top-left y-down space and CG's bottom-left
    /// y-up drawing space (outer flip), then keep the image itself
    /// upright within that space (inner flip).
    private static func renderOverlay(
        path: String, affine: CGAffineTransform, outWidth: Int, outHeight: Int
    ) -> CGImage? {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let src = CGImage(
                pngDataProviderSource: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(
                data: nil, width: outWidth, height: outHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(outHeight)))
        ctx.concatenate(affine)
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(src.height)))
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        return ctx.makeImage()
    }

    /// Alpha-blend the pre-rendered output-space [overlay] over a 32BGRA
    /// frame buffer in place.
    private static func blend(_ overlay: CGImage, onto pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Moves one reader output's samples into one writer input on [queue],
/// holding [group] until the output runs dry, an append fails or [cancel]
/// ends it. [cancel] returns with no append in flight, since a writer must not
/// be cancelled during one. Its state is only touched on [queue].
private final class SamplePump {
    init(
        output: AVAssetReaderOutput, input: AVAssetWriterInput,
        queue: DispatchQueue, group: DispatchGroup,
        process: @escaping (CMSampleBuffer) -> Void = { _ in }
    ) {
        self.output = output
        self.input = input
        self.queue = queue
        self.group = group
        self.process = process
    }

    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    private let group: DispatchGroup
    private let process: (CMSampleBuffer) -> Void
    private var finished = false

    func start() {
        group.enter()
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while !finished && input.isReadyForMoreMediaData {
                guard let buffer = output.copyNextSampleBuffer() else { return finish() }
                process(buffer)
                if !input.append(buffer) { return finish() }
            }
        }
    }

    func cancel() {
        queue.sync { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        input.markAsFinished()
        group.leave()
    }
}

/// One export session's state, touched only on the main queue. A cancel that
/// comes before [attach] aborts the pipeline as soon as it attaches.
private final class ExportTask {
    init(outPath: String) {
        self.outPath = outPath
    }

    let outPath: String
    private(set) var cancelled = false
    private var abort: (() -> Void)?
    var progressTimer: DispatchSourceTimer?

    func attach(abort: @escaping () -> Void) {
        self.abort = abort
        if cancelled { abort() }
    }

    func cancel() {
        cancelled = true
        abort?()
    }
}
