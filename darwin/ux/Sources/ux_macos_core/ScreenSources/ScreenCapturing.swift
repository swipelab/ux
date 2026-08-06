import CoreGraphics
import Foundation

/// Screen capture as a picker snapshot needs it, injected so the core runs
/// without a window server.
public protocol ScreenCapturing: Sendable {
    /// Every display and window the capture stack offers right now.
    func shareableSources() async throws -> [ScreenSource]

    /// A `width` × `height` still of `source`.
    func captureImage(
        of source: ScreenSource,
        width: Int,
        height: Int
    ) async throws -> CGImage
}

/// Why a snapshot cannot be taken at all.
public enum ScreenSourceError: Error, Equatable {
    /// The capture stack cannot enumerate its sources.
    case enumerationFailed(String)

    /// No requested source renders.
    case thumbnailFailed(String)
}
