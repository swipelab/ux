#if os(macOS)

import CoreGraphics
import CoreVideo
import Foundation

/// One camera frame crossing between the host's camera stack and `ux`.
public struct CameraEffectsFrame {
    public init(
        pixelBuffer: CVPixelBuffer,
        crop: CGRect,
        rotationDegrees: Int,
        timestampNs: Int64
    ) {
        self.pixelBuffer = pixelBuffer
        self.crop = crop
        self.rotationDegrees = rotationDegrees
        self.timestampNs = timestampNs
    }

    public let pixelBuffer: CVPixelBuffer

    /// The region of `pixelBuffer` the track publishes, in pixels.
    public let crop: CGRect

    public let rotationDegrees: Int
    public let timestampNs: Int64
}

/// A processing callback the host holds, handed back to remove that exact
/// callback.
public protocol CameraEffectsAttachment: AnyObject {}

/// What removing a callback found.
public enum CameraEffectsDetachOutcome: Equatable, Sendable {
    case removed

    /// The track died under the attachment.
    case alreadyGone
}

/// Why a track would not take a processing callback.
public enum CameraEffectsAttachError: Error, Equatable {
    case unknownTrack
    case failed
}

/// The host's camera stack, as `ux` reaches it. The host app owns the lookup
/// of `trackId` and the frame marshalling; everything else — lifecycle,
/// status, effect policy — stays in `ux`.
///
/// `processing` returns the frame to forward, and runs on whichever thread the
/// host delivers frames on.
public protocol CameraEffectsBridge: AnyObject {
    func attach(
        trackId: String,
        processing: @escaping (CameraEffectsFrame) -> CameraEffectsFrame
    ) throws -> CameraEffectsAttachment

    @discardableResult
    func detach(_ attachment: CameraEffectsAttachment) -> CameraEffectsDetachOutcome
}

#endif
