import Foundation

/// The benchmark rig's lever on the pipeline, for attributing power and heat
/// one stage at a time.
///
/// ```swift
/// CameraEffectsRig.engage(.passthrough)
/// ```
///
/// A release build holds ``CameraEffectStage/composite``: `engage` answers
/// false and moves nothing.
public enum CameraEffectsRig {
    @discardableResult
    public static func engage(_ stage: CameraEffectStage) -> Bool {
        #if DEBUG
            guard #available(macOS 12, iOS 15, *) else { return false }
            guard let processors = CameraEffectHost.processors as? XCameraFrameProcessors
            else { return false }
            processors.stage = stage
            return true
        #else
            return false
        #endif
    }
}
