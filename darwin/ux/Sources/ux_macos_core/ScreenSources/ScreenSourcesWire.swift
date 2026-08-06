import Foundation

/// A `ux/screen_sources` call, decoded.
public enum ScreenSourcesRequest: Equatable, Sendable {
    case available
    case hasPermission
    case requestPermission
    case list(
        allowedDisplayIds: Set<String>,
        allowedWindowIds: Set<String>,
        thumbnailWidth: Int,
        thumbnailHeight: Int
    )
}

/// A call the channel cannot serve, carrying the code Dart raises.
public struct ScreenSourcesFailure: Error, Equatable, Sendable {
    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public let code: String
    public let message: String?
}

extension ScreenSourcesFailure {
    static let unsupported = ScreenSourcesFailure(
        code: "unsupported", message: "macOS 14 or newer"
    )

    static let permissionDenied = ScreenSourcesFailure(
        code: "permission_denied", message: "screen recording is not granted"
    )

    static func invalidRequest(_ field: String, _ detail: String) -> ScreenSourcesFailure {
        ScreenSourcesFailure(code: "invalid_response", message: "\(field): \(detail)")
    }

    init(_ error: Error) {
        switch error {
        case ScreenSourceError.thumbnailFailed(let detail):
            self.init(code: "thumbnail_failed", message: detail)
        case ScreenSourceError.enumerationFailed(let detail):
            self.init(code: "enumeration_failed", message: detail)
        default:
            self.init(code: "enumeration_failed", message: String(describing: error))
        }
    }
}

/// What a request answers with.
public enum ScreenSourcesReply: Equatable, Sendable {
    case flag(Bool)
    case snapshot([ScreenSourceSnapshotItem])
    case failure(ScreenSourcesFailure)
}

/// A method call as decoding leaves it.
public enum ScreenSourcesDecoding: Equatable, Sendable {
    case request(ScreenSourcesRequest)
    case invalid(ScreenSourcesFailure)
    case unknownMethod
}

/// The `ux/screen_sources` argument and result shapes.
public enum ScreenSourcesWire {
    public static func decode(
        method: String,
        arguments: [String: Any]?
    ) -> ScreenSourcesDecoding {
        switch method {
        case "available": return .request(.available)
        case "hasPermission": return .request(.hasPermission)
        case "requestPermission": return .request(.requestPermission)
        case "list": return decodeList(arguments)
        default: return .unknownMethod
        }
    }

    public static func encode(_ items: [ScreenSourceSnapshotItem]) -> [[String: Any]] {
        items.map { item in
            [
                "id": item.source.id,
                "kind": item.source.kind.rawValue,
                "title": item.source.title,
                "applicationName": orNull(item.source.applicationName),
                "sourceWidth": item.source.width,
                "sourceHeight": item.source.height,
                "thumbnailPng": orNull(item.thumbnailPng),
            ]
        }
    }

    private static func decodeList(_ arguments: [String: Any]?) -> ScreenSourcesDecoding {
        guard let arguments else {
            return .invalid(.invalidRequest("arguments", "missing"))
        }
        guard let displays = arguments["allowedDisplayIds"] as? [String] else {
            return .invalid(
                .invalidRequest("allowedDisplayIds", "expected a list of String")
            )
        }
        guard let windows = arguments["allowedWindowIds"] as? [String] else {
            return .invalid(
                .invalidRequest("allowedWindowIds", "expected a list of String")
            )
        }
        guard let width = arguments["thumbnailWidth"] as? Int else {
            return .invalid(.invalidRequest("thumbnailWidth", "expected Int"))
        }
        guard let height = arguments["thumbnailHeight"] as? Int else {
            return .invalid(.invalidRequest("thumbnailHeight", "expected Int"))
        }
        return .request(
            .list(
                allowedDisplayIds: Set(displays),
                allowedWindowIds: Set(windows),
                thumbnailWidth: width,
                thumbnailHeight: height
            )
        )
    }

    private static func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}
