import CoreGraphics
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

/// How much of the pipeline a processor runs.
public enum CameraEffectStage: String, Equatable, Sendable {
    /// The frame crosses the bridge and is copied; no mask, no effect.
    case passthrough

    /// The mask producer runs and the copy ignores what it publishes.
    case maskOnly = "mask-only"

    /// The effect renders under the mask.
    case composite
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
        let mask = producer.mask
        let token = signposts.compositeBegan()
        let outcome = compositor.composite(frame: frame, mask: mask)
        signposts.compositeEnded(token)
        if case .composited(_, _, let maskRejection) = outcome {
            os_unfair_lock_lock(lock)
            rejection = maskRejection
            os_unfair_lock_unlock(lock)
        }
        return CameraFrameOutcome(
            outcome: outcome, processor: self, mask: mask, use: Self.use(of: outcome, mask: mask)
        )
    }

    private static func use(
        of outcome: CompositeOutcome, mask: CameraMask?
    ) -> CameraCompositeUse {
        switch outcome {
        case .substituted(_, let reason):
            return .substituted(reason)
        case .composited(_, _, let rejection):
            if let rejection { return .rejected(rejection) }
            return mask == nil ? .maskless : .used
        }
    }

    public func retire() {
        producer.reset()
    }
}

/// A processor stopping short of the production path: the composite takes no
/// mask, and a mask producer runs only when one is given — the published frame
/// is a copy whatever that producer publishes. The snapshot the composite is
/// denied still goes to the mask's own structural predicate, so the frame
/// reports the use the production path would have made of it.
public final class StagedFrameProcessor: CameraEffectProcessor {
    public init(compositor: CameraEffectCompositor, producer: PersonMaskProducer?) {
        self.compositor = compositor
        self.producer = producer
    }

    private let compositor: CameraEffectCompositor
    let producer: PersonMaskProducer?

    public func process(_ frame: CameraFrame) -> CameraFrameOutcome {
        producer?.consider(frame)
        let mask = producer?.mask
        let outcome = compositor.composite(frame: frame, mask: nil)
        return CameraFrameOutcome(
            outcome: outcome,
            processor: self,
            mask: mask,
            use: Self.use(of: outcome, mask: mask, over: frame.crop)
        )
    }

    private static func use(
        of outcome: CompositeOutcome, mask: CameraMask?, over crop: CGRect
    ) -> CameraCompositeUse {
        if case .substituted(_, let reason) = outcome { return .substituted(reason) }
        guard let mask else { return .maskless }
        if let rejection = mask.rejection(over: crop) { return .rejected(rejection) }
        return .used
    }

    public func retire() {
        producer?.reset()
    }
}

/// Builds the host's processors: one compositor and one Vision-backed mask
/// producer per effect. `stage` is what ``CameraEffectsRig`` moves to price one
/// part of the pipeline at a time; every processor built after it changes runs
/// that much.
@available(macOS 12, iOS 15, *)
public final class XCameraFrameProcessors: CameraEffectProcessorFactory {
    public init() {}

    private let lock = NSLock()
    private var staged = CameraEffectStage.composite

    var stage: CameraEffectStage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return staged
        }
        set {
            lock.lock()
            staged = newValue
            lock.unlock()
        }
    }

    public func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        let measures = CameraEffectHost.composites.exposes
        switch stage {
        case .composite:
            return XCameraFrameProcessor(
                compositor: CameraEffectCompositor(effect: effect, measures: measures),
                producer: PersonMaskProducer(segmenter: VisionPersonSegmenter())
            )
        case .maskOnly:
            return StagedFrameProcessor(
                compositor: CameraEffectCompositor(effect: .none, measures: measures),
                producer: PersonMaskProducer(segmenter: VisionPersonSegmenter())
            )
        case .passthrough:
            return StagedFrameProcessor(
                compositor: CameraEffectCompositor(effect: .none, measures: measures),
                producer: nil
            )
        }
    }
}
