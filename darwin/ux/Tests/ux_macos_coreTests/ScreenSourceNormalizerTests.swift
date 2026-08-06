import XCTest

@testable import ux_macos_core

final class ScreenSourceNormalizerTests: XCTestCase {
    func testNormalizeTrimsTitle() {
        let source = ScreenSourceNormalizer.normalize(
            kind: .window,
            id: "42",
            title: "  Inbox — Mail \n",
            applicationName: "Mail",
            width: 1440,
            height: 900
        )

        XCTAssertEqual(
            source,
            ScreenSource(
                kind: .window,
                id: "42",
                title: "Inbox — Mail",
                applicationName: "Mail",
                width: 1440,
                height: 900
            )
        )
    }

    func testNormalizeDropsBlankApplicationName() {
        let unnamed = ScreenSourceNormalizer.normalize(
            kind: .display,
            id: "1",
            title: "Built-in Retina Display",
            width: 3024,
            height: 1964
        )
        let blank = ScreenSourceNormalizer.normalize(
            kind: .window,
            id: "7",
            title: "Untitled",
            applicationName: "   ",
            width: 800,
            height: 600
        )

        XCTAssertNil(unnamed.applicationName)
        XCTAssertNil(blank.applicationName)
    }

    func testKindScopesTheIdNamespace() {
        let display = ScreenSourceNormalizer.normalize(
            kind: .display,
            id: "3",
            title: "Display",
            width: 100,
            height: 100
        )
        let window = ScreenSourceNormalizer.normalize(
            kind: .window,
            id: "3",
            title: "Display",
            width: 100,
            height: 100
        )

        XCTAssertNotEqual(display, window)
    }
}
