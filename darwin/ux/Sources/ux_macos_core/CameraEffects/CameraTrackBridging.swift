import CoreGraphics
import CoreVideo
import Foundation

/// A camera frame's rotation: one of four quarter turns, and nothing else.
public enum CameraFrameRotation: Int, Equatable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270
}

/// One camera frame as it crosses the bridge, carrying everything the host
/// needs to publish a processed frame in the shape the camera's own frame had.
public struct CameraFrame {
    public init(
        pixelBuffer: CVPixelBuffer,
        crop: CGRect,
        adaptedWidth: Int,
        adaptedHeight: Int,
        rotation: CameraFrameRotation,
        timestampNs: Int64,
        timestamp90kHz: Int32
    ) {
        self.pixelBuffer = pixelBuffer
        self.crop = crop
        self.adaptedWidth = adaptedWidth
        self.adaptedHeight = adaptedHeight
        self.rotation = rotation
        self.timestampNs = timestampNs
        self.timestamp90kHz = timestamp90kHz
    }

    public let pixelBuffer: CVPixelBuffer

    /// The region of `pixelBuffer` the track publishes, in pixels.
    public let crop: CGRect

    /// The size `crop` is scaled to on publication, in pixels.
    public let adaptedWidth: Int
    public let adaptedHeight: Int

    public let rotation: CameraFrameRotation
    public let timestampNs: Int64

    /// The frame's stamp on the 90 kHz media clock, which runs independently of
    /// `timestampNs`.
    public let timestamp90kHz: Int32
}

/// A processing callback the bridge holds, handed back to remove that exact
/// callback. It names the track it was created for.
public protocol CameraTrackAttachment: AnyObject {
    var trackId: String { get }
}

/// What removing a callback found.
public enum CameraTrackDetachOutcome: Equatable, Sendable {
    case removed

    /// The track died under the attachment.
    case alreadyGone

    /// The id now names a different track, which never took the callback. The
    /// track that did keeps it until it dies.
    case trackReplaced
}

/// Why a track would not take a processing callback.
public enum CameraTrackAttachFailure: Error, Equatable {
    case unknownTrack
    case failed
}

/// The host's camera stack, as the effects core needs it: install a processing
/// callback on one track, remove it by identity, release everything on
/// teardown.
///
/// A frame the bridge cannot present as a `CVPixelBuffer` does not reach
/// `processing`; the bridge publishes it as it stands.
public protocol CameraTrackBridging: AnyObject {
    func attach(
        trackId: String,
        processing: @escaping (CameraFrame) -> CameraFrame
    ) throws -> CameraTrackAttachment

    @discardableResult
    func detach(_ attachment: CameraTrackAttachment) -> CameraTrackDetachOutcome

    /// Releases everything the bridge holds. It arrives after the detach of a
    /// live attachment, and never while the bridge is still installed.
    func teardown()
}
