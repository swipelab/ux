import XCTest

@testable import ux_macos_core

final class CameraEffectsRetentionTests: XCTestCase {
    func testCyclesBalanceAttachesWithDetachesAndReleaseTheLastCallback() {
        let harness = CameraEffectsHarness()

        for cycle in 0..<50 {
            harness.send(
                .setEffect(trackId: "t\(cycle)", effect: .blur, generation: cycle * 2 + 1)
            )
            harness.deliverFrame(count: 10)
            if cycle < 49 {
                harness.send(.clear(generation: cycle * 2 + 2))
            }
        }

        XCTAssertNotNil(harness.fakeProcessors?.last)

        harness.send(.clear(generation: 100))

        XCTAssertEqual(harness.bridge.attachCount, 50)
        XCTAssertEqual(harness.bridge.detachCount, 50)
        XCTAssertEqual(harness.bridge.attachCount, harness.bridge.detachCount)
        XCTAssertTrue(harness.bridge.live.isEmpty)
        XCTAssertNil(harness.fakeProcessors?.last)
    }
}
