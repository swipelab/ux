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

    private func fail(_ sessionId: Int, _ code: String, _ message: String) {
        emit(["sessionId": sessionId, "type": "error", "code": code, "message": message])
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

        result(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                return self.fail(sessionId, "no_video_track", "no video track in \(path)")
            }

            let fullDuration = asset.duration
            let startTime = trimStartMs.map { CMTime(value: $0, timescale: 1000) } ?? .zero
            let endTime = trimEndMs.map { CMTime(value: $0, timescale: 1000) } ?? fullDuration
            let range = CMTimeRange(start: startTime, end: CMTimeMinimum(endTime, fullDuration))
            guard range.duration.seconds > 0 else {
                return self.fail(sessionId, "bad_trim", "empty trim range")
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
                return self.fail(sessionId, "compose_failed", error.localizedDescription)
            }

            let durationMs = Int((range.duration.seconds * 1000).rounded())

            if let transform, transform.count == 9,
               let outWidth, let outHeight, let compVideo {
                self.exportTransformed(
                    sessionId: sessionId, composition: composition,
                    compVideo: compVideo, sourceTransform: Self.uprightTransform(of: videoTrack),
                    affine: transform, outWidth: outWidth, outHeight: outHeight,
                    videoBitrate: videoBitrate ?? 3_000_000, hasAudio: !removeAudio,
                    overlayPath: overlayPath,
                    outPath: outPath, durationMs: durationMs)
            } else {
                compVideo?.preferredTransform = videoTrack.preferredTransform
                self.exportPassthrough(
                    sessionId: sessionId, composition: composition,
                    videoTrack: videoTrack, outPath: outPath, durationMs: durationMs)
            }
        }
    }

    // MARK: - Passthrough (trim / mute) — lossless remux

    private func exportPassthrough(
        sessionId: Int, composition: AVMutableComposition,
        videoTrack: AVAssetTrack, outPath: String, durationMs: Int
    ) {
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough
        ) else {
            return fail(sessionId, "session_failed", "could not create export session")
        }

        let outUrl = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outUrl)
        session.outputURL = outUrl
        session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov

        let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let outWidth = Int(abs(natural.width).rounded())
        let outHeight = Int(abs(natural.height).rounded())

        let task = ExportTask(outPath: outPath) { session.cancelExport() }
        DispatchQueue.main.async { self.sessions[sessionId] = task }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self, weak session] in
            guard let session else { return }
            self?.emit(["sessionId": sessionId, "type": "progress", "value": Double(session.progress)])
        }
        timer.resume()
        task.progressTimer = timer

        session.exportAsynchronously { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.sessions[sessionId]?.progressTimer?.cancel()
                self.sessions[sessionId] = nil
            }
            switch session.status {
            case .completed:
                self.emit([
                    "sessionId": sessionId, "type": "done", "path": outPath,
                    "width": outWidth, "height": outHeight, "durationMs": durationMs,
                ])
            case .cancelled:
                try? FileManager.default.removeItem(at: outUrl)
                self.fail(sessionId, "cancelled", "export cancelled")
            default:
                try? FileManager.default.removeItem(at: outUrl)
                self.fail(sessionId, "export_failed", session.error?.localizedDescription ?? "unknown")
            }
        }
    }

    // MARK: - Transform (crop / rotate / flip) — re-encode

    private func exportTransformed(
        sessionId: Int, composition: AVMutableComposition,
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
            return fail(sessionId, "session_failed", error.localizedDescription)
        }

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = videoComposition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            return fail(sessionId, "session_failed", "reader rejects video output")
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
            return fail(sessionId, "session_failed", "writer rejects video input")
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
            return fail(sessionId, "session_failed",
                        reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let cancelled = Cancelled()
        let task = ExportTask(outPath: outPath) {
            cancelled.value = true
            reader.cancelReading()
            writer.cancelWriting()
        }
        DispatchQueue.main.async { self.sessions[sessionId] = task }

        let totalSeconds = max(composition.duration.seconds, 0.001)
        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "ux.video.export.video.\(sessionId)")
        let audioQueue = DispatchQueue(label: "ux.video.export.audio.\(sessionId)")

        group.enter()
        videoIn.requestMediaDataWhenReady(on: videoQueue) {
            while videoIn.isReadyForMoreMediaData {
                if cancelled.value { videoIn.markAsFinished(); group.leave(); return }
                if let buffer = videoOut.copyNextSampleBuffer() {
                    if let overlayOut,
                       let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
                        Self.blend(overlayOut, onto: pixelBuffer)
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    self.emit(["sessionId": sessionId, "type": "progress",
                               "value": min(pts / totalSeconds, 1.0)])
                    if !videoIn.append(buffer) { videoIn.markAsFinished(); group.leave(); return }
                } else {
                    videoIn.markAsFinished(); group.leave(); return
                }
            }
        }

        if let audioOut, let audioIn {
            group.enter()
            audioIn.requestMediaDataWhenReady(on: audioQueue) {
                while audioIn.isReadyForMoreMediaData {
                    if cancelled.value { audioIn.markAsFinished(); group.leave(); return }
                    if let buffer = audioOut.copyNextSampleBuffer() {
                        if !audioIn.append(buffer) { audioIn.markAsFinished(); group.leave(); return }
                    } else {
                        audioIn.markAsFinished(); group.leave(); return
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.sessions[sessionId] = nil
            if cancelled.value {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outUrl)
                return self.fail(sessionId, "cancelled", "export cancelled")
            }
            if reader.status == .failed {
                try? FileManager.default.removeItem(at: outUrl)
                return self.fail(sessionId, "export_failed", reader.error?.localizedDescription ?? "read failed")
            }
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        self.emit([
                            "sessionId": sessionId, "type": "done", "path": outPath,
                            "width": outWidth, "height": outHeight, "durationMs": durationMs,
                        ])
                    } else {
                        try? FileManager.default.removeItem(at: outUrl)
                        self.fail(sessionId, "export_failed",
                                  writer.error?.localizedDescription ?? "write failed")
                    }
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

private final class Cancelled {
    var value = false
}

private final class ExportTask {
    init(outPath: String, cancel: @escaping () -> Void) {
        self.outPath = outPath
        self.cancel = cancel
    }

    let outPath: String
    let cancel: () -> Void
    var progressTimer: DispatchSourceTimer?
}
