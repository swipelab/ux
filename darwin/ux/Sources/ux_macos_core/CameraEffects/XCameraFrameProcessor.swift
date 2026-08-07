import CoreVideo
import Foundation
import os

/// Marks the interval a composite spends rendering.
public protocol CameraEffectSignposting: AnyObject {
    func compositeBegan() -> UInt64
    func compositeEnded(_ token: UInt64)
}

/// `os_signpost` intervals under the capability's subsystem and category.
public final class CameraEffectSignposts: CameraEffectSignposting {
    public static let subsystem = "com.swipelab.ux"
    public static let category = "CameraEffects"

    public init() {}

    private let log = OSLog(
        subsystem: CameraEffectSignposts.subsystem,
        category: CameraEffectSignposts.category
    )

    public func compositeBegan() -> UInt64 {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "composite", signpostID: id)
        return id.rawValue
    }

    public func compositeEnded(_ token: UInt64) {
        os_signpost(.end, log: log, name: "composite", signpostID: OSSignpostID(token))
    }
}

/// The production frame processor: every frame feeds the mask producer it
/// owns, is composited with the newest published mask, and reports its
/// outcome. Nothing it returns is the raw input.
public final class XCameraFrameProcessor: CameraEffectProcessor {
    public init(
        compositor: CameraEffectCompositor,
        producer: PersonMaskProducer,
        signposts: CameraEffectSignposting = CameraEffectSignposts()
    ) {
        self.compositor = compositor
        self.producer = producer
        self.signposts = signposts
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private let compositor: CameraEffectCompositor
    let producer: PersonMaskProducer
    private let signposts: CameraEffectSignposting
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var rejection: CameraMaskRejection?

    /// Why the newest composite set its mask aside; recorded for diagnosis,
    /// never emitted — the whole-frame composite is correct output.
    public var lastMaskRejection: CameraMaskRejection? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return rejection
    }

    public func process(_ frame: CameraFrame) -> CameraFrameOutcome {
        producer.consider(frame)
        let token = signposts.compositeBegan()
        let outcome = compositor.composite(frame: frame, mask: producer.mask)
        signposts.compositeEnded(token)
        if case .composited(_, let maskRejection) = outcome {
            os_unfair_lock_lock(lock)
            rejection = maskRejection
            os_unfair_lock_unlock(lock)
        }
        return CameraFrameOutcome(outcome: outcome, processor: self)
    }

    public func retire() {
        producer.reset()
    }
}

#if os(macOS)

/// Builds the host's processors: one compositor and one Vision-backed mask
/// producer per effect.
@available(macOS 12, *)
public final class XCameraFrameProcessors: CameraEffectProcessorFactory {
    public init() {}

    public func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: effect),
            producer: PersonMaskProducer(segmenter: VisionPersonSegmenter())
        )
    }
}

#endif
