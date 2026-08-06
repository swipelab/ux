import Foundation

/// A `ux/camera_effects` call, decoded.
public enum CameraEffectsRequest: Equatable, Sendable {
    case available
    case setEffect(trackId: String, effect: CameraEffect, generation: Int)
    case clear(generation: Int)
}

/// What a request answers with.
public enum CameraEffectsReply: Equatable, Sendable {
    case flag(Bool)
    case done
    case failure(CameraEffectsFailure)
}

/// A method call as decoding leaves it.
public enum CameraEffectsDecoding: Equatable, Sendable {
    case request(CameraEffectsRequest)
    case invalid(CameraEffectsFailure)
    case unknownMethod
}

/// The `ux/camera_effects` argument and event shapes.
public enum CameraEffectsWire {
    public static func decode(
        method: String,
        arguments: [String: Any]?
    ) -> CameraEffectsDecoding {
        switch method {
        case "available": return .request(.available)
        case "setEffect": return decodeSetEffect(arguments)
        case "clear": return decodeClear(arguments)
        default: return .unknownMethod
        }
    }

    public static func encode(_ status: CameraEffectStatus) -> [String: Any] {
        var event: [String: Any] = [
            "phase": status.phase.rawValue,
            "effect": status.effect.rawValue,
            "generation": status.generation,
        ]
        if let code = status.code { event["code"] = code }
        return event
    }

    private static func decodeSetEffect(
        _ arguments: [String: Any]?
    ) -> CameraEffectsDecoding {
        guard let arguments else {
            return .invalid(.invalidRequest("arguments", "missing"))
        }
        guard let trackId = arguments["trackId"] as? String else {
            return .invalid(.invalidRequest("trackId", "expected String"))
        }
        guard let name = arguments["effect"] as? String else {
            return .invalid(.invalidRequest("effect", "expected String"))
        }
        guard let effect = CameraEffect(rawValue: name), effect != .none else {
            return .invalid(.invalidRequest("effect", "expected blur or dim"))
        }
        guard let generation = generation(arguments) else {
            return .invalid(.invalidRequest("generation", "expected Int"))
        }
        return .request(
            .setEffect(trackId: trackId, effect: effect, generation: generation)
        )
    }

    private static func decodeClear(
        _ arguments: [String: Any]?
    ) -> CameraEffectsDecoding {
        guard let arguments, let generation = generation(arguments) else {
            return .invalid(.invalidRequest("generation", "expected Int"))
        }
        return .request(.clear(generation: generation))
    }

    private static func generation(_ arguments: [String: Any]) -> Int? {
        arguments["generation"] as? Int
    }
}
