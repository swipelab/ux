#if os(macOS)

import Foundation
import ux_macos_core

/// Where the host app hands `ux` its camera stack.
///
/// ```swift
/// CameraEffects.install(MyCameraEffectsBridge())
/// ```
///
/// With nothing installed, every effect command answers
/// `integration_unavailable` and `available()` answers false.
public enum CameraEffects {
    public static func install(_ bridge: CameraEffectsBridge) {
        service.install(CameraEffectsBridgeAdapter(bridge))
    }

    /// Drops the bridge. A live attachment is reported failed at this moment
    /// rather than at the next command.
    public static func uninstall() {
        service.uninstall()
    }

    public static var isInstalled: Bool { service.isBridgeInstalled }

    static let service = CameraEffectsService(
        processors: hostProcessors(),
        scheduler: MainQueueScheduler()
    )

    private static func hostProcessors() -> CameraEffectProcessorFactory? {
        guard #available(macOS 12.0, *) else { return nil }
        return PassthroughEffectProcessors()
    }
}

/// Presents ``CameraEffectsBridge`` as the seam the effects core owns.
final class CameraEffectsBridgeAdapter: CameraTrackBridging {
    init(_ bridge: CameraEffectsBridge) {
        self.bridge = bridge
    }

    private let bridge: CameraEffectsBridge

    func attach(
        trackId: String,
        processing: @escaping (CameraFrame) -> CameraFrame
    ) throws -> CameraTrackAttachment {
        do {
            return Handle(
                try bridge.attach(trackId: trackId) { frame in
                    Self.published(processing(Self.taken(frame)))
                }
            )
        } catch CameraEffectsAttachError.unknownTrack {
            throw CameraTrackAttachFailure.unknownTrack
        } catch {
            throw CameraTrackAttachFailure.failed
        }
    }

    func detach(_ attachment: CameraTrackAttachment) -> CameraTrackDetachOutcome {
        guard let handle = attachment as? Handle else { return .alreadyGone }
        switch bridge.detach(handle.attachment) {
        case .removed: return .removed
        case .alreadyGone: return .alreadyGone
        }
    }

    private static func taken(_ frame: CameraEffectsFrame) -> CameraFrame {
        CameraFrame(
            pixelBuffer: frame.pixelBuffer,
            crop: frame.crop,
            rotationDegrees: frame.rotationDegrees,
            timestampNs: frame.timestampNs
        )
    }

    private static func published(_ frame: CameraFrame) -> CameraEffectsFrame {
        CameraEffectsFrame(
            pixelBuffer: frame.pixelBuffer,
            crop: frame.crop,
            rotationDegrees: frame.rotationDegrees,
            timestampNs: frame.timestampNs
        )
    }

    private final class Handle: CameraTrackAttachment {
        init(_ attachment: CameraEffectsAttachment) {
            self.attachment = attachment
        }

        let attachment: CameraEffectsAttachment
    }
}

#endif
