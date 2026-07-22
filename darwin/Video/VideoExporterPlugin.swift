import AVFoundation
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// `ux/video/export` (+`/events`) — trim / mute video export.
///
/// Trim + audio-drop compose an `AVMutableComposition` and run it
/// through `AVAssetExportSession` with the passthrough preset: a
/// lossless remux, no re-encode. Progress is polled from
/// `session.progress` on a timer and streamed per-session; cancel
/// aborts the session and deletes the partial output.
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

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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

        result(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                return self.emit([
                    "sessionId": sessionId, "type": "error",
                    "code": "no_video_track", "message": "no video track in \(path)",
                ])
            }

            let fullDuration = asset.duration
            let startTime = trimStartMs.map { CMTime(value: $0, timescale: 1000) } ?? .zero
            let endTime = trimEndMs.map { CMTime(value: $0, timescale: 1000) } ?? fullDuration
            let range = CMTimeRange(start: startTime, end: CMTimeMinimum(endTime, fullDuration))
            guard range.duration.seconds > 0 else {
                return self.emit([
                    "sessionId": sessionId, "type": "error",
                    "code": "bad_trim", "message": "empty trim range",
                ])
            }

            let composition = AVMutableComposition()
            do {
                let compVideo = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try compVideo?.insertTimeRange(range, of: videoTrack, at: .zero)
                compVideo?.preferredTransform = videoTrack.preferredTransform

                if !removeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
                    let compAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                    try compAudio?.insertTimeRange(range, of: audioTrack, at: .zero)
                }
            } catch {
                return self.emit([
                    "sessionId": sessionId, "type": "error",
                    "code": "compose_failed", "message": error.localizedDescription,
                ])
            }

            guard let session = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                return self.emit([
                    "sessionId": sessionId, "type": "error",
                    "code": "session_failed", "message": "could not create export session",
                ])
            }

            let outUrl = URL(fileURLWithPath: outPath)
            try? FileManager.default.removeItem(at: outUrl)
            session.outputURL = outUrl
            session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov

            // Rotation-aware output dims for the result payload.
            let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            let outWidth = Int(abs(natural.width).rounded())
            let outHeight = Int(abs(natural.height).rounded())
            let durationMs = Int((range.duration.seconds * 1000).rounded())

            let task = ExportTask(session: session, outPath: outPath)
            DispatchQueue.main.async { self.sessions[sessionId] = task }

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self, weak session] in
                guard let session else { return }
                self?.emit([
                    "sessionId": sessionId, "type": "progress",
                    "value": Double(session.progress),
                ])
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
                        "sessionId": sessionId, "type": "done",
                        "path": outPath,
                        "width": outWidth, "height": outHeight,
                        "durationMs": durationMs,
                    ])
                case .cancelled:
                    try? FileManager.default.removeItem(at: outUrl)
                    self.emit([
                        "sessionId": sessionId, "type": "error",
                        "code": "cancelled", "message": "export cancelled",
                    ])
                default:
                    try? FileManager.default.removeItem(at: outUrl)
                    self.emit([
                        "sessionId": sessionId, "type": "error",
                        "code": "export_failed",
                        "message": session.error?.localizedDescription ?? "unknown",
                    ])
                }
            }
        }
    }

    private func cancel(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = (args["sessionId"] as? NSNumber)?.intValue else {
            return result(FlutterError(code: "bad_args", message: "sessionId required", details: nil))
        }
        sessions[sessionId]?.session.cancelExport()
        result(nil)
    }
}

private final class ExportTask {
    init(session: AVAssetExportSession, outPath: String) {
        self.session = session
        self.outPath = outPath
    }

    let session: AVAssetExportSession
    let outPath: String
    var progressTimer: DispatchSourceTimer?
}
