import CoreGraphics
import CoreVideo
import Foundation

@testable import ux_macos_core

func makeCameraFrame(timestampNs: Int64 = 0) -> CameraFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
    return CameraFrame(
        pixelBuffer: buffer!,
        crop: CGRect(x: 0, y: 0, width: 2, height: 2),
        rotationDegrees: 0,
        timestampNs: timestampNs
    )
}

final class FakeCameraTrackBridge: CameraTrackBridging {
    final class Attachment: CameraTrackAttachment {
        init(trackId: String, processing: @escaping (CameraFrame) -> CameraFrame) {
            self.trackId = trackId
            self.processing = processing
        }

        let trackId: String
        var processing: ((CameraFrame) -> CameraFrame)?

        func deliverFrame(_ frame: CameraFrame = makeCameraFrame()) {
            _ = processing?(frame)
        }
    }

    var attachError: Error?

    private(set) var attachCount = 0
    private(set) var detachCount = 0
    private(set) var attachedTracks: [String] = []
    private(set) var detachedIdentities: [ObjectIdentifier] = []
    private(set) var live: [Attachment] = []

    func attach(
        trackId: String,
        processing: @escaping (CameraFrame) -> CameraFrame
    ) throws -> CameraTrackAttachment {
        if let attachError { throw attachError }
        attachCount += 1
        attachedTracks.append(trackId)
        let attachment = Attachment(trackId: trackId, processing: processing)
        live.append(attachment)
        return attachment
    }

    @discardableResult
    func detach(_ attachment: CameraTrackAttachment) -> CameraTrackDetachOutcome {
        detachCount += 1
        guard
            let target = attachment as? Attachment,
            let index = live.firstIndex(where: { $0 === target })
        else { return .alreadyGone }
        detachedIdentities.append(ObjectIdentifier(target))
        live.remove(at: index)
        target.processing = nil
        return .removed
    }

    /// The track dies under the attachment: the next detach finds nothing.
    func lose(_ attachment: Attachment) {
        live.removeAll { $0 === attachment }
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

final class FakeEffectProcessor: CameraEffectProcessor {
    private(set) var frames = 0

    func process(_ frame: CameraFrame) -> CameraFrame {
        frames += 1
        return frame
    }
}

final class FakeEffectProcessors: CameraEffectProcessorFactory {
    var error: Error?

    private(set) var requested: [CameraEffect] = []

    /// Weak so a retention assertion sees the processor released.
    private(set) weak var last: FakeEffectProcessor?

    func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        requested.append(effect)
        if let error { throw error }
        let processor = FakeEffectProcessor()
        last = processor
        return processor
    }
}

enum FakeProcessorError: Error {
    case standUp
}

/// A service wired to fakes, with the plugin's own listen/seed shape.
final class CameraEffectsHarness {
    init(processors: CameraEffectProcessorFactory? = FakeEffectProcessors(), installed: Bool = true) {
        self.processors = processors
        service = CameraEffectsService(
            processors: processors,
            scheduler: scheduler,
            delivery: ImmediateDelivery()
        )
        if installed { service.install(bridge) }
    }

    let bridge = FakeCameraTrackBridge()
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

    func deliverFrame(count: Int = 1) {
        guard let attachment = bridge.live.last else { return }
        for index in 0..<count {
            attachment.deliverFrame(makeCameraFrame(timestampNs: Int64(index)))
        }
    }
}
