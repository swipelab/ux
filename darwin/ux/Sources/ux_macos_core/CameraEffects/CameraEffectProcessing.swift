import Foundation

/// Turns a camera frame into the frame the track publishes.
public protocol CameraEffectProcessor: AnyObject {
    func process(_ frame: CameraFrame) -> CameraFrame
}

/// Stands up the processor for an effect. A `nil` factory is a host below the
/// capability's floor: every command answers `unsupported`.
public protocol CameraEffectProcessorFactory: AnyObject {
    func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor
}

/// Publishes the camera's own frames.
public final class PassthroughEffectProcessor: CameraEffectProcessor {
    public init() {}

    public func process(_ frame: CameraFrame) -> CameraFrame { frame }
}

public final class PassthroughEffectProcessors: CameraEffectProcessorFactory {
    public init() {}

    public func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        PassthroughEffectProcessor()
    }
}
