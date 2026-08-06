#if os(macOS)

import CoreGraphics
import CoreVideo
import Foundation

/// A camera frame's rotation: one of four quarter turns, and nothing else.
public enum CameraEffectsRotation: Int, Equatable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270
}

/// One camera frame crossing between the host's camera stack and `ux`, carrying
/// everything the host needs to publish a processed frame in the shape the
/// camera's own frame had.
public struct CameraEffectsFrame {
    public init(
        pixelBuffer: CVPixelBuffer,
        crop: CGRect,
        adaptedWidth: Int,
        adaptedHeight: Int,
        rotation: CameraEffectsRotation,
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

    public let rotation: CameraEffectsRotation
    public let timestampNs: Int64

    /// The frame's stamp on the 90 kHz media clock, which runs independently of
    /// `timestampNs`.
    public let timestamp90kHz: Int32
}

/// A processing callback the host holds, handed back to remove that exact
/// callback. It names the track it was created for.
public protocol CameraEffectsAttachment: AnyObject {
    var trackId: String { get }
}

/// What removing a callback found.
public enum CameraEffectsDetachOutcome: Equatable, Sendable {
    case removed

    /// The track died under the attachment.
    case alreadyGone

    /// The id now names a different track, which never took the callback. The
    /// track that did keeps it until it dies.
    case trackReplaced
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
/// host delivers frames on. A frame the host cannot present as a
/// `CVPixelBuffer` does not reach `processing`; the host publishes it as it
/// stands.
public protocol CameraEffectsBridge: AnyObject {
    func attach(
        trackId: String,
        processing: @escaping (CameraEffectsFrame) -> CameraEffectsFrame
    ) throws -> CameraEffectsAttachment

    @discardableResult
    func detach(_ attachment: CameraEffectsAttachment) -> CameraEffectsDetachOutcome

    /// Releases everything the bridge holds. `ux` calls it from
    /// ``CameraEffects/uninstall()``, after detaching a live attachment.
    func teardown()
}

#endif
