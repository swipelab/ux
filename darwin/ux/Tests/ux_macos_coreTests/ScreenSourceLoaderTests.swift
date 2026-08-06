import XCTest

@testable import ux_macos_core

final class ScreenSourceLoaderTests: XCTestCase {
    private func source(
        _ kind: ScreenSourceKind,
        _ id: String,
        title: String = "Source",
        applicationName: String? = nil,
        width: Int = 1920,
        height: Int = 1080
    ) -> ScreenSource {
        ScreenSource(
            kind: kind,
            id: id,
            title: title,
            applicationName: applicationName,
            width: width,
            height: height
        )
    }

    func testSnapshotNormalizesAndOrdersDisplaysBeforeWindows() async throws {
        let capture = FakeScreenCapture(sources: [
            source(.window, "8", title: "  Inbox \n", applicationName: " Mail "),
            source(.display, "2", title: "Sidecar"),
            source(.window, "5", title: "Notes", applicationName: "  "),
            source(.display, "1", title: "Built-in"),
        ])
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: ["1", "2"],
            allowedWindowIds: ["5", "8"],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertEqual(
            snapshot.map { "\($0.source.kind.rawValue):\($0.source.id)" },
            ["display:2", "display:1", "window:8", "window:5"]
        )
        XCTAssertEqual(snapshot[2].source.title, "Inbox")
        XCTAssertEqual(snapshot[2].source.applicationName, "Mail")
        XCTAssertNil(snapshot[3].source.applicationName)
        XCTAssertTrue(snapshot.allSatisfy { $0.thumbnailPng?.isEmpty == false })
    }

    func testIntersectionIsScopedByKind() async throws {
        let capture = FakeScreenCapture(sources: [
            source(.display, "3"),
            source(.window, "3"),
        ])
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: ["3"],
            allowedWindowIds: ["9"],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].source.kind, .display)
    }

    func testOneFailingSourceKeepsTheRestAndSucceeds() async throws {
        let sources = [
            source(.display, "1"),
            source(.window, "5"),
            source(.window, "6"),
        ]
        let capture = FakeScreenCapture(sources: sources)
        await capture.vanish("window:5")
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: ["1"],
            allowedWindowIds: ["5", "6"],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertEqual(snapshot.count, 3)
        XCTAssertNotNil(snapshot[0].thumbnailPng)
        XCTAssertNil(snapshot[1].thumbnailPng)
        XCTAssertEqual(snapshot[1].source.id, "5")
        XCTAssertNotNil(snapshot[2].thumbnailPng)
    }

    func testVanishedSourceYieldsANilThumbnail() async throws {
        let capture = FakeScreenCapture(sources: [
            source(.window, "5"),
            source(.window, "6"),
        ])
        await capture.vanish("window:6")
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: [],
            allowedWindowIds: ["5", "6"],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertEqual(snapshot.map(\.source.id), ["5", "6"])
        XCTAssertNil(snapshot[1].thumbnailPng)
    }

    func testEveryFailingSourceThrowsThumbnailFailed() async {
        let capture = FakeScreenCapture(sources: [
            source(.display, "1"),
            source(.window, "5"),
        ])
        await capture.vanish("display:1", "window:5")
        let loader = ScreenSourceLoader(capture: capture)

        do {
            _ = try await loader.snapshot(
                allowedDisplayIds: ["1"],
                allowedWindowIds: ["5"],
                thumbnailWidth: 320,
                thumbnailHeight: 180
            )
            XCTFail("expected thumbnailFailed")
        } catch {
            XCTAssertEqual(
                error as? ScreenSourceError,
                .thumbnailFailed("2 source(s) failed to render")
            )
        }
    }

    func testEnumerationFailureThrowsEnumerationFailed() async {
        let capture = FakeScreenCapture(enumerationError: FakeCaptureError.enumeration)
        let loader = ScreenSourceLoader(capture: capture)

        do {
            _ = try await loader.snapshot(
                allowedDisplayIds: ["1"],
                allowedWindowIds: [],
                thumbnailWidth: 320,
                thumbnailHeight: 180
            )
            XCTFail("expected enumerationFailed")
        } catch {
            guard case .enumerationFailed = error as? ScreenSourceError else {
                return XCTFail("expected enumerationFailed, got \(error)")
            }
        }
    }

    func testAspectFitDimensionsAreEncodedIntoThePng() async throws {
        let capture = FakeScreenCapture(sources: [
            source(.window, "1", width: 1920, height: 1080),
            source(.window, "2", width: 1080, height: 1920),
            source(.window, "3", width: 1000, height: 1000),
        ])
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: [],
            allowedWindowIds: ["1", "2", "3"],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        let sizes = try snapshot.map { item -> ScreenThumbnailSize in
            let png = try XCTUnwrap(item.thumbnailPng)
            return try XCTUnwrap(pngSize(png))
        }
        XCTAssertEqual(
            sizes,
            [
                ScreenThumbnailSize(width: 320, height: 180),
                ScreenThumbnailSize(width: 101, height: 180),
                ScreenThumbnailSize(width: 180, height: 180),
            ]
        )
        let requested = await capture.requestedSizes
        XCTAssertEqual(requested["window:1"], ScreenThumbnailSize(width: 320, height: 180))
    }

    func testAspectFitClampsDegenerateSizes() {
        XCTAssertEqual(
            ScreenThumbnailRenderer.aspectFit(
                source: ScreenThumbnailSize(width: 4000, height: 1),
                into: ScreenThumbnailSize(width: 320, height: 180)
            ),
            ScreenThumbnailSize(width: 320, height: 1)
        )
        XCTAssertEqual(
            ScreenThumbnailRenderer.aspectFit(
                source: ScreenThumbnailSize(width: 0, height: 0),
                into: ScreenThumbnailSize(width: 320, height: 180)
            ),
            ScreenThumbnailSize(width: 320, height: 180)
        )
    }

    func testNoRequestedSourcesReturnsAnEmptySnapshot() async throws {
        let capture = FakeScreenCapture(sources: [source(.display, "1")])
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: [],
            allowedWindowIds: [],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertTrue(snapshot.isEmpty)
        let enumerations = await capture.enumerations
        XCTAssertEqual(enumerations, 0)
    }

    func testNoAllowedSourcePresentReturnsAnEmptySnapshot() async throws {
        let capture = FakeScreenCapture(sources: [source(.display, "1")])
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: ["77"],
            allowedWindowIds: [],
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertTrue(snapshot.isEmpty)
    }

    func testRendersAtMostThreeSourcesConcurrently() async throws {
        let sources = (1...9).map { source(.window, "\($0)") }
        let capture = FakeScreenCapture(sources: sources)
        let loader = ScreenSourceLoader(capture: capture)

        let snapshot = try await loader.snapshot(
            allowedDisplayIds: [],
            allowedWindowIds: Set(sources.map(\.id)),
            thumbnailWidth: 320,
            thumbnailHeight: 180
        )

        XCTAssertEqual(snapshot.count, 9)
        let peak = await capture.peakConcurrency
        XCTAssertEqual(peak, 3)
    }
}
