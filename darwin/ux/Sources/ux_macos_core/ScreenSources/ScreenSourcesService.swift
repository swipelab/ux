import Foundation

/// The screen-recording grant, injected so the core runs without TCC.
public protocol ScreenPermissions: Sendable {
    /// Whether screen recording is granted. Never prompts.
    var isGranted: Bool { get }

    /// Asks for screen recording, answering the state the ask leaves behind.
    func request() -> Bool
}

/// Serves one decoded `ux/screen_sources` request.
public struct ScreenSourcesService: Sendable {
    /// A `nil` `capture` is a host without the snapshot capability:
    /// `available` answers false and `list` fails `unsupported`.
    public init(capture: ScreenCapturing?, permissions: ScreenPermissions) {
        self.capture = capture
        self.permissions = permissions
    }

    private let capture: ScreenCapturing?
    private let permissions: ScreenPermissions

    public func reply(to request: ScreenSourcesRequest) async -> ScreenSourcesReply {
        switch request {
        case .available:
            return .flag(capture != nil)
        case .hasPermission:
            return .flag(permissions.isGranted)
        case .requestPermission:
            return .flag(permissions.request())
        case .list(let displays, let windows, let width, let height):
            return await snapshot(
                allowedDisplayIds: displays,
                allowedWindowIds: windows,
                thumbnailWidth: width,
                thumbnailHeight: height
            )
        }
    }

    private func snapshot(
        allowedDisplayIds: Set<String>,
        allowedWindowIds: Set<String>,
        thumbnailWidth: Int,
        thumbnailHeight: Int
    ) async -> ScreenSourcesReply {
        guard let capture else { return .failure(.unsupported) }
        guard permissions.isGranted else { return .failure(.permissionDenied) }
        do {
            return .snapshot(
                try await ScreenSourceLoader(capture: capture).snapshot(
                    allowedDisplayIds: allowedDisplayIds,
                    allowedWindowIds: allowedWindowIds,
                    thumbnailWidth: thumbnailWidth,
                    thumbnailHeight: thumbnailHeight
                )
            )
        } catch {
            return .failure(ScreenSourcesFailure(error))
        }
    }
}
