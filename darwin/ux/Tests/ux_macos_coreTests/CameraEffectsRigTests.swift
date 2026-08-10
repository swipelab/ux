import Foundation
import XCTest

@testable import ux_macos_core

final class CameraEffectsRigTests: XCTestCase {
    override func tearDown() {
        CameraEffectsRig.engage(.composite)
        super.tearDown()
    }

    private func hostProcessors() throws -> CameraEffectProcessorFactory {
        guard let processors = CameraEffectHost.processors else {
            throw XCTSkip("this host is below \(CameraEffectHost.requirement)")
        }
        return processors
    }

    // MARK: - Wire vocabulary

    func testEveryStageAnswersToItsWireName() {
        XCTAssertEqual(CameraEffectStage(rawValue: "mask-only"), .maskOnly)
        XCTAssertEqual(CameraEffectStage(rawValue: "passthrough"), .passthrough)
        XCTAssertEqual(CameraEffectStage(rawValue: "composite"), .composite)
    }

    func testANameNoStageCarriesResolvesToNothing() {
        XCTAssertNil(CameraEffectStage(rawValue: "maskOnly"))
        XCTAssertNil(CameraEffectStage(rawValue: "mask_only"))
        XCTAssertNil(CameraEffectStage(rawValue: ""))
    }

    // MARK: - Engaging

    func testEngageMovesTheFactoryUnderTheProcessorsBuiltAfterIt() throws {
        let processors = try hostProcessors()
        let before = try processors.makeProcessor(for: .blur)

        XCTAssertTrue(CameraEffectsRig.engage(.maskOnly))
        let after = try processors.makeProcessor(for: .blur)

        XCTAssertTrue(before is XCameraFrameProcessor)
        XCTAssertTrue(after is StagedFrameProcessor)
        before.retire()
        after.retire()
    }

    func testTheMaskOnlyStageBuildsAProcessorKeepingItsMaskProducer() throws {
        let processors = try hostProcessors()

        XCTAssertTrue(CameraEffectsRig.engage(.maskOnly))
        let processor = try XCTUnwrap(
            processors.makeProcessor(for: .blur) as? StagedFrameProcessor
        )

        XCTAssertNotNil(processor.producer)
        processor.retire()
    }

    func testThePassthroughStageBuildsAProcessorWithNoMaskProducer() throws {
        let processors = try hostProcessors()

        XCTAssertTrue(CameraEffectsRig.engage(.passthrough))
        let processor = try XCTUnwrap(
            processors.makeProcessor(for: .blur) as? StagedFrameProcessor
        )

        XCTAssertNil(processor.producer)
        processor.retire()
    }

    func testEngagingCompositeBringsTheProductionProcessorBack() throws {
        let processors = try hostProcessors()
        XCTAssertTrue(CameraEffectsRig.engage(.passthrough))

        XCTAssertTrue(CameraEffectsRig.engage(.composite))
        let processor = try processors.makeProcessor(for: .blur)

        XCTAssertTrue(processor is XCameraFrameProcessor)
        processor.retire()
    }
}
