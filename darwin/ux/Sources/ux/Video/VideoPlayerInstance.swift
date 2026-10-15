import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
#if canImport(UIKit)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif

/// How [UxVideoPlayerInstance.prepare] ends.
enum UxVideoPrepareResult {
    case ready(size: CGSize, durationMs: Int64, rotationQuarterTurns: Int)
    case failed(Error)
    case disposed
}

/// One per Dart-side `XVideoPlayerController`. Owns the `AVPlayer`,
/// an `AVPlayerItemVideoOutput` that pumps `CVPixelBuffer`s into the
/// Flutter texture, and a periodic timer that fires position +
/// buffered events back to Dart.
///
/// Mirrors the shape of `CameraInstance` — main-thread methods,
/// per-handle event payloads tagged with `handle`.
final class UxVideoPlayerInstance: NSObject {
    let handle: Int
    let textureId: Int64

    /// Pushed to Dart as `{event, handle, …}` payloads. Set by the
    /// plugin in `create`.
    var onEvent: ((/* payload */ [String: Any?]) -> Void)?

    private weak var textureRegistry: FlutterTextureRegistry?
    private let sink: UxVideoPixelBufferSink
    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var pumpTimer: Timer?
    private var positionTimer: Timer?
    private var prepareCompletion: ((UxVideoPrepareResult) -> Void)?

    /// Quarter-turns of clockwise rotation the Flutter `Texture` needs
    /// so the rendered frame reads upright. AVPlayerItemVideoOutput
    /// delivers `CVPixelBuffer`s in the file's *natural* orientation —
    /// the file's `preferredTransform` rotation is NOT applied — while
    /// `item.presentationSize` already reflects the rotated dimensions.
    /// Without surfacing this to Dart, the gallery wraps a
    /// portrait-displayed-as-landscape buffer in a portrait
    /// `AspectRatio` and stretches it. Loaded from the first video
    /// track's `preferredTransform` once the asset's tracks arrive — for
    /// a remote asset, after its header downloads — and nil until then.
    /// [prepare] completes only once it is known.
    private var rotationQuarterTurns: Int?

    private var disposed = false
    private var lastReportedIsPlaying = false
    private var lastReportedIsBuffering = false
    private var lastReportedSize: CGSize = .zero
    private var lastReportedDurationMs: Int64 = -1
    private var notifiedCompleted = false

    private static let pumpHz: TimeInterval = 1.0 / 60.0
    private static let positionHz: TimeInterval = 1.0 / 10.0

    /// `kCVPixelFormatType_32BGRA` keeps the Flutter texture path
    /// happy — Flutter's iOS/macOS embedder expects BGRA8888.
    private static let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]

    init(handle: Int, registry: FlutterTextureRegistry) {
        self.handle = handle
        self.textureRegistry = registry
        self.sink = UxVideoPixelBufferSink()
        self.textureId = sink.register(with: registry)
        super.init()
    }

    // MARK: - Source / prepare

    func setSource(url: URL) {
        let asset = AVURLAsset(url: url)
        let newItem = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: Self.pixelBufferAttributes,
        )
        newItem.add(output)

        item = newItem
        videoOutput = output
        player.replaceCurrentItem(with: newItem)

        addObservers(item: newItem)

        // A tracks load that fails also fails the item, which fails [prepare].
        Task { @MainActor [weak self] in
            let turns = (try? await Self.rotationQuarterTurns(for: asset)) ?? 0
            self?.rotationQuarterTurns = turns
            self?.completePrepare()
        }
    }

    /// Maps the first video track's `preferredTransform` to quarter
    /// turns of clockwise rotation. `atan2(b, a)` recovers the rotation
    /// angle from the affine transform's rotation/scale components;
    /// rounding to the nearest 90° gives a stable enum-like value
    /// (`Int` mod 4) for the Dart-side `RotatedBox`.
    private static func rotationQuarterTurns(for asset: AVAsset) async throws -> Int {
        guard #available(iOS 15, macOS 12, *),
              let track = try await asset.loadTracks(withMediaType: .video).first
        else { return 0 }
        let t = try await track.load(.preferredTransform)
        let radians = atan2(t.b, t.a)
        let degrees = radians * 180.0 / .pi
        let normalized = (Int(degrees.rounded()) % 360 + 360) % 360
        return (normalized / 90) % 4
    }

    func prepare(completion: @escaping (UxVideoPrepareResult) -> Void) {
        guard item != nil else {
            completion(
                .failed(
                    NSError(
                        domain: "ux.video",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "no item"],
                    )
                )
            )
            return
        }
        prepareCompletion = completion
        completePrepare()
    }

    /// Resolves [prepare] once the item is ready to play and the
    /// rotation has loaded.
    private func completePrepare() {
        guard let completion = prepareCompletion,
              let item = item,
              item.status == .readyToPlay,
              let rotationQuarterTurns
        else { return }
        prepareCompletion = nil
        let dims = item.presentationSize
        let durMs = Self.toMs(item.duration)
        lastReportedSize = dims
        lastReportedDurationMs = durMs
        startPumping()
        startPositionTimer()
        emitSizeChanged(dims)
        completion(
            .ready(
                size: dims,
                durationMs: durMs,
                rotationQuarterTurns: rotationQuarterTurns,
            )
        )
    }

    // MARK: - Controls

    func play() {
        guard !disposed else { return }
        player.rate = defaultRate
    }

    func pause() {
        guard !disposed else { return }
        player.pause()
    }

    func seekTo(positionMs: Int64) {
        guard !disposed else { return }
        let time = CMTime(value: max(0, positionMs), timescale: 1000)
        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero,
        )
        emitPosition(forcePositionMs: positionMs)
    }

    func setLooping(_ loop: Bool) {
        guard !disposed else { return }
        loopingEnabled = loop
    }

    func setVolume(_ volume: Float) {
        guard !disposed else { return }
        player.volume = max(0, min(1, volume))
    }

    func setPlaybackSpeed(_ rate: Float) {
        guard !disposed else { return }
        let clamped = max(0.25, min(4.0, rate))
        defaultRate = clamped
        if player.rate != 0 {
            player.rate = clamped
        }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true

        pumpTimer?.invalidate()
        pumpTimer = nil
        positionTimer?.invalidate()
        positionTimer = nil

        if let item = item {
            removeObservers(item: item)
        }
        if let videoOutput = videoOutput, let item = item {
            item.remove(videoOutput)
        }
        videoOutput = nil
        item = nil
        player.replaceCurrentItem(with: nil)
        sink.unregister()
        onEvent = nil
        if let completion = prepareCompletion {
            prepareCompletion = nil
            completion(.disposed)
        }
    }

    // MARK: - Observers / completion

    private var loopingEnabled = false
    /// The rate [play] starts at, in place of `AVPlayer.defaultRate`, which
    /// needs iOS 16 and macOS 13.
    private var defaultRate: Float = 1.0
    private var statusContext = 0
    private var bufferEmptyContext = 1
    private var likelyToKeepUpContext = 2
    private var rateContext = 3

    private func addObservers(item: AVPlayerItem) {
        item.addObserver(
            self,
            forKeyPath: "status",
            options: [.new, .initial],
            context: &statusContext,
        )
        item.addObserver(
            self,
            forKeyPath: "playbackBufferEmpty",
            options: [.new],
            context: &bufferEmptyContext,
        )
        item.addObserver(
            self,
            forKeyPath: "playbackLikelyToKeepUp",
            options: [.new],
            context: &likelyToKeepUpContext,
        )
        player.addObserver(
            self,
            forKeyPath: "rate",
            options: [.new],
            context: &rateContext,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackEnded(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item,
        )
    }

    private func removeObservers(item: AVPlayerItem) {
        item.removeObserver(self, forKeyPath: "status", context: &statusContext)
        item.removeObserver(self, forKeyPath: "playbackBufferEmpty", context: &bufferEmptyContext)
        item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp", context: &likelyToKeepUpContext)
        player.removeObserver(self, forKeyPath: "rate", context: &rateContext)
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: item,
        )
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?,
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.handleObservation(keyPath: keyPath, context: context)
        }
    }

    private func handleObservation(keyPath: String?, context: UnsafeMutableRawPointer?) {
        if context == &statusContext, let item = item {
            switch item.status {
            case .readyToPlay:
                completePrepare()
            case .failed:
                if let completion = prepareCompletion {
                    prepareCompletion = nil
                    completion(
                        .failed(
                            item.error
                                ?? NSError(
                                    domain: "ux.video",
                                    code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "AVPlayerItem failed"],
                                )
                        )
                    )
                } else if let error = item.error {
                    emit([
                        "event": "error",
                        "code": "playback_failed",
                        "description": error.localizedDescription,
                    ])
                }
            default:
                break
            }
        } else if context == &bufferEmptyContext, let item = item {
            let buffering = item.isPlaybackBufferEmpty
            if buffering != lastReportedIsBuffering {
                lastReportedIsBuffering = buffering
                emit([
                    "event": "stateChanged",
                    "isBuffering": buffering,
                    "positionMs": currentPositionMs(),
                ])
            }
        } else if context == &likelyToKeepUpContext, let item = item {
            if item.isPlaybackLikelyToKeepUp && lastReportedIsBuffering {
                lastReportedIsBuffering = false
                emit([
                    "event": "stateChanged",
                    "isBuffering": false,
                    "positionMs": currentPositionMs(),
                ])
            }
        } else if context == &rateContext {
            let playing = player.rate != 0
            if playing != lastReportedIsPlaying {
                lastReportedIsPlaying = playing
                emit([
                    "event": "stateChanged",
                    "isPlaying": playing,
                    "positionMs": currentPositionMs(),
                ])
            }
        }
    }

    @objc private func playbackEnded(_ note: Notification) {
        if loopingEnabled {
            player.seek(to: .zero) { [weak self] _ in
                self?.play()
            }
            return
        }
        if !notifiedCompleted {
            notifiedCompleted = true
            emit([
                "event": "completed",
            ])
        }
    }

    // MARK: - Pumps

    private func startPumping() {
        pumpTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pumpHz, repeats: true) { [weak self] _ in
            self?.pumpFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        let timer = Timer(timeInterval: Self.positionHz, repeats: true) { [weak self] _ in
            self?.emitPosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func pumpFrame() {
        guard let videoOutput = videoOutput else { return }
        let host = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: host) else { return }
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: host,
            itemTimeForDisplay: nil,
        ) else { return }
        sink.deliver(pixelBuffer: pixelBuffer)
    }

    private func emitPosition(forcePositionMs: Int64? = nil) {
        let positionMs = forcePositionMs ?? currentPositionMs()
        let buffered = bufferedRanges()
        emit([
            "event": "stateChanged",
            "positionMs": positionMs,
            "buffered": buffered,
        ])
    }

    private func bufferedRanges() -> [[String: Int64]] {
        guard let item = item else { return [] }
        return item.loadedTimeRanges.map { value -> [String: Int64] in
            let r = value.timeRangeValue
            let startMs = Int64(CMTimeGetSeconds(r.start) * 1000.0)
            let endMs = Int64(CMTimeGetSeconds(r.start + r.duration) * 1000.0)
            return [
                "startMs": max(0, startMs),
                "endMs": max(0, endMs),
            ]
        }
    }

    private func currentPositionMs() -> Int64 {
        let t = player.currentTime()
        return Int64(max(0, CMTimeGetSeconds(t)) * 1000.0)
    }

    private func emitSizeChanged(_ size: CGSize) {
        emit([
            "event": "sizeChanged",
            "size": [
                "width": Double(size.width),
                "height": Double(size.height),
            ] as [String: Any],
        ])
    }

    private func emit(_ extras: [String: Any?]) {
        var payload = extras
        payload["handle"] = handle
        onEvent?(payload)
    }

    private static func toMs(_ t: CMTime) -> Int64 {
        guard t.isValid, !t.isIndefinite else { return 0 }
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite, !seconds.isNaN else { return 0 }
        return Int64(max(0, seconds) * 1000.0)
    }
}

