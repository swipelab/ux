import XCTest

@testable import ux_macos_core

private final class FakeScreenPermissions: ScreenPermissions, @unchecked Sendable {
    init(granted: Bool, grantsOnRequest: Bool? = nil) {
        self.granted = granted
        self.grantsOnRequest = grantsOnRequest ?? granted
    }

    private var granted: Bool
    private let grantsOnRequest: Bool
    private(set) var prompts = 0

    var isGranted: Bool { granted }

    func request() -> Bool {
        prompts += 1
        granted = grantsOnRequest
        return granted
    }
}

private struct UnexpectedReply: Error {
    let reply: ScreenSourcesReply
}

final class ScreenSourcesServiceTests: XCTestCase {
    private func source(
        _ kind: ScreenSourceKind,
        _ id: String,
        title: String = "Source"
    ) -> ScreenSource {
        ScreenSource(
            kind: kind,
            id: id,
            title: title,
            applicationName: nil,
            width: 1920,
            height: 1080
        )
    }

    private func listRequest(
        displays: Set<String> = ["1"],
        windows: Set<String> = ["5"]
    ) -> ScreenSourcesRequest {
        .list(
            allowedDisplayIds: displays,
            allowedWindowIds: windows,
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )
    }

    private func failure(of reply: ScreenSourcesReply) throws -> ScreenSourcesFailure {
        guard case .failure(let failure) = reply else {
            throw UnexpectedReply(reply: reply)
        }
        return failure
    }

    func testAvailableFollowsTheCaptureSeam() async {
        let withCapture = ScreenSourcesService(
            capture: FakeScreenCapture(), permissions: FakeScreenPermissions(granted: true)
        )
        let withoutCapture = ScreenSourcesService(
            capture: nil, permissions: FakeScreenPermissions(granted: true)
        )

        var reply = await withCapture.reply(to: .available)
        XCTAssertEqual(reply, .flag(true))
        reply = await withoutCapture.reply(to: .available)
        XCTAssertEqual(reply, .flag(false))
    }

    func testHasPermissionAnswersTheGrantWithoutPrompting() async {
        let permissions = FakeScreenPermissions(granted: false)
        let service = ScreenSourcesService(
            capture: FakeScreenCapture(), permissions: permissions
        )

        let reply = await service.reply(to: .hasPermission)

        XCTAssertEqual(reply, .flag(false))
        XCTAssertEqual(permissions.prompts, 0)
    }

    func testRequestPermissionPromptsAndAnswersTheStateItLeaves() async {
        let denying = FakeScreenPermissions(granted: false)
        let granting = FakeScreenPermissions(granted: false, grantsOnRequest: true)

        var reply = await ScreenSourcesService(
            capture: FakeScreenCapture(), permissions: denying
        ).reply(to: .requestPermission)
        XCTAssertEqual(reply, .flag(false))
        reply = await ScreenSourcesService(
            capture: FakeScreenCapture(), permissions: granting
        ).reply(to: .requestPermission)
        XCTAssertEqual(reply, .flag(true))

        XCTAssertEqual(denying.prompts, 1)
        XCTAssertEqual(granting.prompts, 1)
    }

    func testListWithoutACaptureSeamIsUnsupported() async throws {
        let permissions = FakeScreenPermissions(granted: true)
        let service = ScreenSourcesService(capture: nil, permissions: permissions)

        let failure = try failure(of: await service.reply(to: listRequest()))

        XCTAssertEqual(failure.code, "unsupported")
        XCTAssertEqual(permissions.prompts, 0)
    }

    func testListWithoutTheGrantIsDeniedWithoutPromptOrEnumeration() async throws {
        let capture = FakeScreenCapture(sources: [source(.display, "1")])
        let permissions = FakeScreenPermissions(granted: false)
        let service = ScreenSourcesService(capture: capture, permissions: permissions)

        let failure = try failure(of: await service.reply(to: listRequest()))

        XCTAssertEqual(failure.code, "permission_denied")
        XCTAssertEqual(permissions.prompts, 0)
        let enumerations = await capture.enumerations
        XCTAssertEqual(enumerations, 0)
    }

    func testListReturnsTheAllowedSnapshot() async throws {
        let capture = FakeScreenCapture(sources: [
            source(.display, "1", title: "Built-in"),
            source(.window, "5", title: "Inbox"),
            source(.window, "6", title: "Notes"),
        ])
        let service = ScreenSourcesService(
            capture: capture, permissions: FakeScreenPermissions(granted: true)
        )

        let reply = await service.reply(to: listRequest(displays: ["1"], windows: ["5"]))

        guard case .snapshot(let items) = reply else {
            throw UnexpectedReply(reply: reply)
        }
        XCTAssertEqual(items.map(\.source.id), ["1", "5"])
        XCTAssertTrue(items.allSatisfy { $0.thumbnailPng?.isEmpty == false })
    }

    func testLoaderFailuresMapOntoTheirWireCodes() async throws {
        let vanishing = FakeScreenCapture(sources: [source(.display, "1")])
        await vanishing.vanish("display:1")
        let table: [(ScreenCapturing, String)] = [
            (
                FakeScreenCapture(enumerationError: FakeCaptureError.enumeration),
                "enumeration_failed"
            ),
            (vanishing, "thumbnail_failed"),
        ]

        for (capture, code) in table {
            let service = ScreenSourcesService(
                capture: capture, permissions: FakeScreenPermissions(granted: true)
            )

            let failure = try failure(of: await service.reply(to: listRequest(windows: [])))

            XCTAssertEqual(failure.code, code)
            XCTAssertNotNil(failure.message)
        }
    }
}
