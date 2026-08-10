import Foundation
import XCTest

@testable import ux_macos_core

final class CameraEffectHostTests: XCTestCase {
    func testTheSegmentationFloorIsTheFamilysOwn() {
        #if os(macOS)
            XCTAssertEqual(CameraEffectHost.family, "macOS")
            XCTAssertEqual(CameraEffectHost.floor.majorVersion, 12)
        #else
            XCTAssertEqual(CameraEffectHost.family, "iOS")
            XCTAssertEqual(CameraEffectHost.floor.majorVersion, 15)
        #endif
    }

    func testTheProcessorFactoryIsThereExactlyWhenTheHostMeetsTheFloor() {
        XCTAssertEqual(
            CameraEffectHost.processors != nil,
            ProcessInfo.processInfo.isOperatingSystemAtLeast(CameraEffectHost.floor)
        )
    }

    func testTheHostFactoryBuildsTheVisionBackedProcessor() throws {
        guard let processors = CameraEffectHost.processors else {
            throw XCTSkip("this host is below \(CameraEffectHost.requirement)")
        }

        let processor = try processors.makeProcessor(for: .blur)

        XCTAssertTrue(processor is XCameraFrameProcessor)
    }

    func testAnUnsupportedReplyNamesTheFamilysFloor() {
        #if os(macOS)
            XCTAssertEqual(CameraEffectsFailure.unsupported.message, "macOS 12 or newer")
        #else
            XCTAssertEqual(CameraEffectsFailure.unsupported.message, "iOS 15 or newer")
        #endif
    }
}
