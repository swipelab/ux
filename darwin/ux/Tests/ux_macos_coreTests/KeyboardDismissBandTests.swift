import XCTest

@testable import ux_macos_core

final class KeyboardDismissBandTests: XCTestCase {
    func testHostViewNames() {
        XCTAssertTrue(KeyboardDismissBand.isHostViewClass("UIInputSetHostView"))
        XCTAssertTrue(KeyboardDismissBand.isHostViewClass("UIKeyboardItemContainerView"))
        XCTAssertFalse(KeyboardDismissBand.isHostViewClass("UIWindow"))
        XCTAssertFalse(KeyboardDismissBand.isHostViewClass("FlutterView"))
    }

    func testWindowNames() {
        XCTAssertTrue(KeyboardDismissBand.isWindowClass("UIRemoteKeyboardWindow"))
        XCTAssertTrue(KeyboardDismissBand.isWindowClass("UITextEffectsWindow"))
        XCTAssertFalse(KeyboardDismissBand.isWindowClass("UIWindow"))
    }

    func testBandIsTheComposerAndKeyboardSlot() {
        // window 852, IME 301, composer 48 → band starts at 503.
        XCTAssertTrue(
            KeyboardDismissBand.contains(
                y: 850, windowHeight: 852, keyboardHeight: 301, trackingInset: 48
            )
        )
        XCTAssertTrue(
            KeyboardDismissBand.contains(
                y: 510, windowHeight: 852, keyboardHeight: 301, trackingInset: 48
            )
        )
        XCTAssertFalse(
            KeyboardDismissBand.contains(
                y: 200, windowHeight: 852, keyboardHeight: 301, trackingInset: 48
            )
        )
        XCTAssertFalse(
            KeyboardDismissBand.contains(
                y: 850, windowHeight: 852, keyboardHeight: 0, trackingInset: 48
            )
        )
    }

    func testBandInAKeyboardSizedWindow() {
        // The IME window may be only as tall as the keyboard; a touch
        // on that view is in the band.
        XCTAssertTrue(
            KeyboardDismissBand.contains(
                y: 10, windowHeight: 301, keyboardHeight: 301, trackingInset: 48
            )
        )
    }

    func testBeginsDismissIsDownwardDominant() {
        XCTAssertTrue(KeyboardDismissBand.beginsDismiss(velocityX: 10, velocityY: 80))
        XCTAssertFalse(KeyboardDismissBand.beginsDismiss(velocityX: 200, velocityY: 50))
        XCTAssertFalse(KeyboardDismissBand.beginsDismiss(velocityX: 0, velocityY: -100))
    }
}
