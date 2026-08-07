import Foundation

/// What the outgoing camera track carries behind the person.
public enum CameraEffect: String, Equatable, Sendable {
    case none
    case blur
    case dim
}

/// How far an effect has got.
public enum CameraEffectPhase: String, Equatable, Sendable {
    case idle
    case applying
    case active
    case failed
}

/// The effect on the track, the phase it is in, and the generation of the
/// last command the platform took.
public struct CameraEffectStatus: Equatable, Sendable {
    public init(
        phase: CameraEffectPhase,
        effect: CameraEffect,
        generation: Int,
        code: String? = nil
    ) {
        self.phase = phase
        self.effect = effect
        self.generation = generation
        self.code = code
    }

    public let phase: CameraEffectPhase
    public let effect: CameraEffect
    public let generation: Int
    public let code: String?
}

extension CameraEffectStatus {
    static func idle(generation: Int) -> CameraEffectStatus {
        CameraEffectStatus(phase: .idle, effect: .none, generation: generation)
    }

    static func applying(
        _ effect: CameraEffect,
        generation: Int
    ) -> CameraEffectStatus {
        CameraEffectStatus(phase: .applying, effect: effect, generation: generation)
    }

    static func active(
        _ effect: CameraEffect,
        generation: Int
    ) -> CameraEffectStatus {
        CameraEffectStatus(phase: .active, effect: effect, generation: generation)
    }

    static func failed(
        _ effect: CameraEffect,
        generation: Int,
        code: String
    ) -> CameraEffectStatus {
        CameraEffectStatus(
            phase: .failed, effect: effect, generation: generation, code: code
        )
    }
}

/// Codes that ride the status stream and are never thrown.
public enum CameraEffectStatusCode {
    /// Processing stopped after the effect was active.
    public static let processingFailed = "processing_failed"
}

/// A command the channel cannot serve, carrying the code Dart raises.
public struct CameraEffectsFailure: Error, Equatable, Sendable {
    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public let code: String
    public let message: String?
}

extension CameraEffectsFailure {
    static let unsupported = CameraEffectsFailure(
        code: "unsupported", message: "macOS 12 or newer"
    )

    static let integrationUnavailable = CameraEffectsFailure(
        code: "integration_unavailable", message: "no camera bridge installed"
    )

    static let trackNotFound = CameraEffectsFailure(
        code: "track_not_found", message: "the bridge holds no such track"
    )

    static let trackNotProcessable = CameraEffectsFailure(
        code: "track_not_processable",
        message: "no frame reached the processor before the attach deadline"
    )

    static let initializationFailed = CameraEffectsFailure(
        code: "initialization_failed", message: "the processor did not start"
    )

    static func invalidRequest(_ field: String, _ detail: String) -> CameraEffectsFailure {
        CameraEffectsFailure(code: "invalid_response", message: "\(field): \(detail)")
    }
}
