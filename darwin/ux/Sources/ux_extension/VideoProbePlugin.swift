import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Describes a video file in one round-trip for `XVideoProbe`: upright display
/// dimensions, duration, and a poster frame. AVFoundation only — no player, no
/// texture registry — so an app extension can host it where `XVideoPlayer`
/// cannot. A missing poster is reported as a probe without one; only a file
/// with no video track at all comes back nil.
public class VideoProbePlugin: NSObject {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
        let messenger = registrar.messenger()
        #else
        let messenger = registrar.messenger
        #endif
        let c = FlutterMethodChannel(name: "ux/video_probe", binaryMessenger: messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "probe": handleProbe(call, result: result)
        default:      result(FlutterMethodNotImplemented)
        }
    }

    private func handleProbe(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let atMs = (args["atMs"] as? NSNumber)?.intValue ?? 0
        // nil = poster at native resolution.
        let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        DispatchQueue.global(qos: .userInitiated).async {
            guard let track = asset.tracks(withMediaType: .video).first else {
                return DispatchQueue.main.async { result(nil) }
            }
            let size = track.naturalSize.applying(track.preferredTransform)
            var reply: [String: Any] = [
                "width": Int(abs(size.width).rounded()),
                "height": Int(abs(size.height).rounded()),
                "durationMs": Int((CMTimeGetSeconds(asset.duration) * 1000).rounded()),
            ]
            if let png = Self.poster(of: asset, atMs: atMs, maxWidth: maxWidth) {
                reply["png"] = FlutterStandardTypedData(bytes: png)
            }
            DispatchQueue.main.async { result(reply) }
        }
    }

    private static func poster(of asset: AVAsset, atMs: Int, maxWidth: Int?) -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 0 on the second axis preserves the aspect ratio; .zero is no cap.
        generator.maximumSize = maxWidth.map { CGSize(width: CGFloat($0), height: 0) } ?? .zero
        // Tolerate a few hundred ms of slop so we can land on a keyframe.
        generator.requestedTimeToleranceBefore = CMTime(value: 500, timescale: 1000)
        generator.requestedTimeToleranceAfter = CMTime(value: 500, timescale: 1000)
        guard let frame = try? generator.copyCGImage(
            at: CMTime(value: Int64(atMs) * 1000, timescale: 1_000_000), actualTime: nil)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
