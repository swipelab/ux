import CoreGraphics
import CoreVideo
import Foundation

@testable import ux_macos_core

func makeCameraFrame(
    crop: CGRect = CGRect(x: 0, y: 0, width: 2, height: 2),
    adaptedWidth: Int = 2,
    adaptedHeight: Int = 2,
    rotation: CameraFrameRotation = .degrees0,
    timestampNs: Int64 = 0,
    timestamp90kHz: Int32 = 0
) -> CameraFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
    return CameraFrame(
        pixelBuffer: buffer!,
        crop: crop,
        adaptedWidth: adaptedWidth,
        adaptedHeight: adaptedHeight,
        rotation: rotation,
        timestampNs: timestampNs,
        timestamp90kHz: timestamp90kHz
    )
}

/// The host's tracks, which outlive any one bridge: a track takes as many
/// processing callbacks as are put on it, and only the object currently under
/// an id can be reached by that id.
final class FakeTrackWorld {
    final class Track {
        init(id: String) { self.id = id }

        let id: String
        var registrations: [FakeCameraTrackBridge.Attachment] = []
    }

    private var tracks: [String: Track] = [:]

    func track(_ id: String) -> Track {
        if let track = tracks[id] { return track }
        let track = Track(id: id)
        tracks[id] = track
        return track
    }

    func current(_ id: String) -> Track? { tracks[id] }

    /// The id comes to name a different track object.
    func replaceTrack(_ id: String) {
        tracks[id] = Track(id: id)
    }

    /// The track dies: nothing answers to `id`, and its callbacks die with it.
    func removeTrack(_ id: String) {
        tracks[id]?.registrations.removeAll()
        tracks[id] = nil
    }

    func registrations(on id: String) -> Int { tracks[id]?.registrations.count ?? 0 }
}

final class FakeCameraTrackBridge: CameraTrackBridging {
    init(world: FakeTrackWorld = FakeTrackWorld()) {
        self.world = world
    }

    let world: FakeTrackWorld

    final class Attachment: CameraTrackAttachment {
        init(
            track: FakeTrackWorld.Track,
            processing: @escaping (CameraFrame) -> CameraFrame
        ) {
            self.track = track
            self.processing = processing
        }

        let track: FakeTrackWorld.Track
        var processing: ((CameraFrame) -> CameraFrame)?

        private(set) var unprocessedFrames = 0

        var trackId: String { track.id }

        @discardableResult
        func deliverFrame(_ frame: CameraFrame = makeCameraFrame()) -> CameraFrame? {
            processing?(frame)
        }

        /// A frame the bridge cannot present as a `CVPixelBuffer`: it is
        /// published without reaching `processing`.
        func forwardUnprocessedFrame() {
            unprocessedFrames += 1
        }
    }

    var attachError: Error?

    private(set) var attachCount = 0
    private(set) var detachCount = 0
    private(set) var teardownCount = 0
    private(set) var attachedTracks: [String] = []
    private(set) var detachedIdentities: [ObjectIdentifier] = []
    private(set) var outcomes: [CameraTrackDetachOutcome] = []
    private(set) var calls: [Call] = []

    enum Call: Equatable {
        case attach(String)
        case detach(String)
        case teardown
    }

    private var attachments: [Attachment] = []

    /// The attachments whose callback is still registered on its track.
    var live: [Attachment] {
        attachments.filter { attachment in
            attachment.track.registrations.contains { $0 === attachment }
        }
    }

    func attach(
        trackId: String,
        processing: @escaping (CameraFrame) -> CameraFrame
    ) throws -> CameraTrackAttachment {
        if let attachError { throw attachError }
        attachCount += 1
        attachedTracks.append(trackId)
        calls.append(.attach(trackId))
        let track = world.track(trackId)
        let attachment = Attachment(track: track, processing: processing)
        track.registrations.append(attachment)
        attachments.append(attachment)
        return attachment
    }

    @discardableResult
    func detach(_ attachment: CameraTrackAttachment) -> CameraTrackDetachOutcome {
        detachCount += 1
        calls.append(.detach(attachment.trackId))
        let outcome = remove(attachment)
        outcomes.append(outcome)
        return outcome
    }

    func teardown() {
        teardownCount += 1
        calls.append(.teardown)
    }

    /// The track dies under the attachment: the next detach finds nothing.
    func lose(_ attachment: Attachment) {
        world.removeTrack(attachment.trackId)
    }

    /// Removal reaches the track through its id alone.
    private func remove(_ attachment: CameraTrackAttachment) -> CameraTrackDetachOutcome {
        guard let target = attachment as? Attachment else { return .alreadyGone }
        guard let track = world.current(target.trackId) else { return .alreadyGone }
        guard track === target.track else { return .trackReplaced }
        guard let index = track.registrations.firstIndex(where: { $0 === target }) else {
            return .alreadyGone
        }
        detachedIdentities.append(ObjectIdentifier(target))
        track.registrations.remove(at: index)
        target.processing = nil
        return .removed
    }
}

final class FakeCameraEffectsScheduler: CameraEffectsScheduling {
    final class Work: CameraEffectsScheduledWork {
        init(delay: TimeInterval, body: @escaping () -> Void) {
            self.delay = delay
            self.body = body
        }

        let delay: TimeInterval
        let body: () -> Void
        var cancelled = false
        var fired = false

        func cancel() { cancelled = true }
    }

    private(set) var scheduled: [Work] = []

    var armed: [Work] { scheduled.filter { !$0.cancelled && !$0.fired } }

    func schedule(
        after delay: TimeInterval,
        _ body: @escaping () -> Void
    ) -> CameraEffectsScheduledWork {
        let work = Work(delay: delay, body: body)
        scheduled.append(work)
        return work
    }

    /// Runs every deadline that is still armed.
    func advance() {
        for work in armed {
            work.fired = true
            work.body()
        }
    }
}

final class ImmediateDelivery: CameraEffectsDelivering {
    func deliver(_ body: @escaping () -> Void) { body() }
}

/// A processor the tests script: it answers composited or substituted, and
/// can hold `process` open until released so a switch lands mid-frame.
final class FakeEffectProcessor: CameraEffectProcessor {
    enum Answer {
        case composite
        case substitute
    }

    private let state = NSCondition()
    private var scripted = Answer.composite
    private var holding = false
    private var processed = 0
    private var retires = 0

    var answer: Answer {
        get {
            state.lock()
            defer { state.unlock() }
            return scripted
        }
        set {
            state.lock()
            scripted = newValue
            state.unlock()
        }
    }

    var frames: Int {
        state.lock()
        defer { state.unlock() }
        return processed
    }

    var retireCount: Int {
        state.lock()
        defer { state.unlock() }
        return retires
    }

    /// Blocks the next `process` calls until `release()`.
    func hold() {
        state.lock()
        holding = true
        state.unlock()
    }

    func release() {
        state.lock()
        holding = false
        state.broadcast()
        state.unlock()
    }

    @discardableResult
    func waitForFrames(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while processed < count {
            if !state.wait(until: deadline) { return false }
        }
        return true
    }

    func process(_ frame: CameraFrame) -> CameraFrameOutcome {
        state.lock()
        processed += 1
        state.broadcast()
        while holding { state.wait() }
        let answer = scripted
        state.unlock()
        switch answer {
        case .composite:
            return CameraFrameOutcome(
                outcome: .composited(frame, maskRejection: nil), processor: self
            )
        case .substitute:
            return CameraFrameOutcome(
                outcome: .substituted(frame, reason: .renderFailed), processor: self
            )
        }
    }

    func retire() {
        state.lock()
        retires += 1
        state.unlock()
    }
}

final class FakeEffectProcessors: CameraEffectProcessorFactory {
    var error: Error?

    /// Vended before any self-made processor, in order.
    var prepared: [CameraEffectProcessor] = []

    private(set) var requested: [CameraEffect] = []

    /// Weak so a retention assertion sees the processor released.
    private(set) weak var last: FakeEffectProcessor?

    func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        requested.append(effect)
        if let error { throw error }
        if !prepared.isEmpty { return prepared.removeFirst() }
        let processor = FakeEffectProcessor()
        last = processor
        return processor
    }
}

/// Rebuilds every frame from its parts, so a field the frame type cannot carry
/// does not survive processing.
final class RebuildingEffectProcessor: CameraEffectProcessor {
    func process(_ frame: CameraFrame) -> CameraFrameOutcome {
        let rebuilt = CameraFrame(
            pixelBuffer: frame.pixelBuffer,
            crop: frame.crop,
            adaptedWidth: frame.adaptedWidth,
            adaptedHeight: frame.adaptedHeight,
            rotation: frame.rotation,
            timestampNs: frame.timestampNs,
            timestamp90kHz: frame.timestamp90kHz
        )
        return CameraFrameOutcome(
            outcome: .composited(rebuilt, maskRejection: nil), processor: self
        )
    }

    func retire() {}
}

final class RebuildingEffectProcessors: CameraEffectProcessorFactory {
    func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        RebuildingEffectProcessor()
    }
}

enum FakeProcessorError: Error {
    case standUp
}

/// A service wired to fakes, with the plugin's own listen/seed shape.
final class CameraEffectsHarness {
    init(
        processors: CameraEffectProcessorFactory? = FakeEffectProcessors(),
        installed: Bool = true,
        world: FakeTrackWorld = FakeTrackWorld()
    ) {
        self.processors = processors
        self.world = world
        bridge = FakeCameraTrackBridge(world: world)
        service = CameraEffectsService(
            processors: processors,
            scheduler: scheduler,
            delivery: ImmediateDelivery()
        )
        if installed { service.install(bridge) }
    }

    let world: FakeTrackWorld
    let bridge: FakeCameraTrackBridge
    let scheduler = FakeCameraEffectsScheduler()
    let processors: CameraEffectProcessorFactory?
    let service: CameraEffectsService

    private(set) var events: [CameraEffectStatus] = []

    var fakeProcessors: FakeEffectProcessors? { processors as? FakeEffectProcessors }

    final class Box {
        var value: CameraEffectsReply?
    }

    @discardableResult
    func send(_ request: CameraEffectsRequest) -> Box {
        let box = Box()
        service.reply(to: request) { box.value = $0 }
        return box
    }

    func listen() {
        events.append(service.currentStatus)
        service.setStatusObserver { [weak self] status in
            self?.events.append(status)
        }
    }

    func cancelListen() {
        service.setStatusObserver(nil)
    }

    /// 30 fps capture.
    static let frameIntervalNs: Int64 = 33_333_333

    private static let frameInterval = TimeInterval(frameIntervalNs) / 1_000_000_000

    /// The longest run of frames that stays inside the sustained-substitution
    /// window.
    static let framesInsideWindow = Int(
        (CameraEffectsService.sustainedSubstitution / frameInterval).rounded(.up)
    )

    /// The shortest run of frames that covers that window.
    static let framesPastWindow = framesInsideWindow + 1

    private var timestampNs: Int64 = 0

    /// Frames on one capture clock that spans every call.
    func deliverFrame(count: Int = 1) {
        guard let attachment = bridge.live.last else { return }
        for _ in 0..<count {
            attachment.deliverFrame(makeCameraFrame(timestampNs: timestampNs))
            timestampNs += Self.frameIntervalNs
        }
    }
}
