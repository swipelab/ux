import Foundation

/// One frame's result: the frame the track publishes, how it was produced,
/// and the processor that produced it, so the service can drop outcomes
/// arriving from a processor it no longer holds. `mask` is the object the
/// processor snapshotted for this frame, which `use` describes the fate of.
public struct CameraFrameOutcome {
    public init(
        outcome: CompositeOutcome,
        processor: CameraEffectProcessor,
        mask: CameraMask?,
        use: CameraCompositeUse
    ) {
        self.outcome = outcome
        self.processor = processor
        self.mask = mask
        self.use = use
    }

    public let outcome: CompositeOutcome
    public let processor: CameraEffectProcessor
    public let mask: CameraMask?
    public let use: CameraCompositeUse

    public var frame: CameraFrame { outcome.frame }
}

/// Turns a camera frame into the frame the track publishes and reports what
/// that frame produced. `retire` releases what the processor holds for its
/// effect; a `process` already in flight completes and returns its output.
public protocol CameraEffectProcessor: AnyObject {
    func process(_ frame: CameraFrame) -> CameraFrameOutcome
    func retire()
}

/// Stands up the processor for an effect. A `nil` factory is a host below the
/// capability's floor: every command answers `unsupported`.
public protocol CameraEffectProcessorFactory: AnyObject {
    func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor
}

/// Publishes the camera's own frames.
public final class PassthroughEffectProcessor: CameraEffectProcessor {
    public init() {}

    public func process(_ frame: CameraFrame) -> CameraFrameOutcome {
        CameraFrameOutcome(
            outcome: .composited(frame, background: nil, maskRejection: nil),
            processor: self,
            mask: nil,
            use: .maskless
        )
    }

    public func retire() {}
}

public final class PassthroughEffectProcessors: CameraEffectProcessorFactory {
    public init() {}

    public func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        PassthroughEffectProcessor()
    }
}
