import Foundation

/// The person segmentation this platform family carries: the OS Vision first
/// ships it in, the requirement an `unsupported` reply names, and the
/// processor factory that exists only at or above that OS.
public enum CameraEffectHost {
    #if os(macOS)
        public static let family = "macOS"

        public static let floor = OperatingSystemVersion(
            majorVersion: 12, minorVersion: 0, patchVersion: 0
        )
    #else
        public static let family = "iOS"

        public static let floor = OperatingSystemVersion(
            majorVersion: 15, minorVersion: 0, patchVersion: 0
        )
    #endif

    public static var requirement: String {
        "\(family) \(floor.majorVersion) or newer"
    }

    /// The one factory the process serves every effect from, and the one
    /// ``CameraEffectsRig`` moves. `nil` below ``floor``, where every command
    /// answers `unsupported`.
    public static let processors: CameraEffectProcessorFactory? = makeProcessors()

    private static func makeProcessors() -> CameraEffectProcessorFactory? {
        guard #available(macOS 12, iOS 15, *) else { return nil }
        return XCameraFrameProcessors()
    }

    /// The one log the process records its composites into and
    /// ``CameraEffectsRig`` reads. A release build neither fills nor measures
    /// for it.
    public static let composites: CameraCompositeLog = {
        #if DEBUG
            return CameraCompositeLog(exposes: true)
        #else
            return CameraCompositeLog(exposes: false)
        #endif
    }()

    /// The one log every mask producer in the process accounts to and
    /// ``CameraEffectsRig`` reads. A release build neither fills nor measures
    /// for it.
    public static let masks: CameraMaskLog = {
        #if DEBUG
            return CameraMaskLog(exposes: true)
        #else
            return CameraMaskLog(exposes: false)
        #endif
    }()
}
