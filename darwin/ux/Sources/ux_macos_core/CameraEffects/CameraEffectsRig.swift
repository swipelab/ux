import Foundation

/// The benchmark rig's lever on the pipeline and its window onto what the
/// pipeline composited, for attributing power and heat one stage at a time and
/// for reading what each published frame made of its mask.
///
/// ```swift
/// CameraEffectsRig.engage(.passthrough)
/// ```
///
/// A release build holds ``CameraEffectStage/composite`` and records nothing:
/// `engage` answers false and moves nothing, `composites` answers empty.
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

    /// Every composite the log still holds, oldest first.
    public static func composites() -> [CameraCompositeRecord] {
        CameraEffectHost.composites.records()
    }
}
