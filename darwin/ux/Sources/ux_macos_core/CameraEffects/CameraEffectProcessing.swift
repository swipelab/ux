import Foundation

/// One frame's result: the frame the track publishes, how it was produced,
/// and the processor that produced it, so the service can drop outcomes
/// arriving from a processor it no longer holds.
public struct CameraFrameOutcome {
    public init(outcome: CompositeOutcome, processor: CameraEffectProcessor) {
        self.outcome = outcome
        self.processor = processor
    }

    public let outcome: CompositeOutcome
    public let processor: CameraEffectProcessor

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
            outcome: .composited(frame, maskRejection: nil), processor: self
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
