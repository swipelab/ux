#if os(macOS)

import AppKit
import XCTest

@testable import ux_macos_core

final class ReduceMotionObserverTests: XCTestCase {
    private func postDisplayOptionsChange() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
        )
    }

    func testReadsAtInitAndOnEachDisplayOptionsChangeUntilReleased() {
        var setting = false
        var sent: [Bool] = []
        withExtendedLifetime(ReduceMotionObserver(read: { setting }, onChange: { sent.append($0) })) {
            setting = true
            postDisplayOptionsChange()
            setting = false
            postDisplayOptionsChange()
        }
        setting = true
        postDisplayOptionsChange()
        XCTAssertEqual(sent, [false, true, false])
    }

    func testReadsTheWorkspaceSetting() {
        var sent: [Bool] = []
        withExtendedLifetime(ReduceMotionObserver(onChange: { sent.append($0) })) {}
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        print("reduceMotion: \(reduced)")
        XCTAssertEqual(sent, [reduced])
    }
}

#endif
