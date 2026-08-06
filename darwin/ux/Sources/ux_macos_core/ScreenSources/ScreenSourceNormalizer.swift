import Foundation

public enum ScreenSourceKind: String, Sendable {
    case display
    case window
}

public struct ScreenSource: Equatable, Sendable {
    public init(
        kind: ScreenSourceKind,
        id: String,
        title: String,
        applicationName: String?,
        width: Int,
        height: Int
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.width = width
        self.height = height
    }

    public let kind: ScreenSourceKind

    /// Identifier in the capture stack's own namespace, scoped by `kind`:
    /// selection hands it straight back to that stack.
    public let id: String

    public let title: String
    public let applicationName: String?
    public let width: Int
    public let height: Int
}

public enum ScreenSourceNormalizer {
    public static func normalize(
        kind: ScreenSourceKind,
        id: String,
        title: String,
        applicationName: String? = nil,
        width: Int,
        height: Int
    ) -> ScreenSource {
        ScreenSource(
            kind: kind,
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationName: nonEmpty(applicationName),
            width: width,
            height: height
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
