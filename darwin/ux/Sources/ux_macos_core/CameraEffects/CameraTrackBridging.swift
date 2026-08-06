import CoreGraphics
import CoreVideo
import Foundation

/// One camera frame as it crosses the bridge.
public struct CameraFrame {
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

/// A processing callback the bridge holds, handed back to remove that exact
/// callback.
public protocol CameraTrackAttachment: AnyObject {}

/// What removing a callback found.
public enum CameraTrackDetachOutcome: Equatable, Sendable {
    case removed

    /// The track died under the attachment.
    case alreadyGone
}

/// Why a track would not take a processing callback.
public enum CameraTrackAttachFailure: Error, Equatable {
    case unknownTrack
    case failed
}

/// The host's camera stack, as the effects core needs it: install a
/// processing callback on one track, remove it by identity.
public protocol CameraTrackBridging: AnyObject {
    func attach(
        trackId: String,
        processing: @escaping (CameraFrame) -> CameraFrame
    ) throws -> CameraTrackAttachment

    @discardableResult
    func detach(_ attachment: CameraTrackAttachment) -> CameraTrackDetachOutcome
}
