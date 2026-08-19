import XCTest

final class AudioCaptureStartOrderTests: XCTestCase {
    func testStartMicrophoneEnablesVoiceProcessingBeforeSelectingTheInput() throws {
        let body = try functionBody(
            named: "private func startMicrophone",
            until: "private func startPlayback",
            in: pluginSource()
        )
        let voiceProcessing = try XCTUnwrap(
            body.range(of: "setVoiceProcessingEnabled(true)")
        )
        let select = try XCTUnwrap(body.range(of: "AudioInputs.select"))
        XCTAssertLessThan(voiceProcessing.lowerBound, select.lowerBound)
    }

    func testStartMicrophoneEnablesVoiceProcessingOnlyWhenAsked() throws {
        let body = try functionBody(
            named: "private func startMicrophone",
            until: "private func startPlayback",
            in: pluginSource()
        )
        let gate = try XCTUnwrap(body.range(of: "if voiceProcessing"))
        let afterGate = body[gate.upperBound...]
        let enable = try XCTUnwrap(afterGate.range(of: "setVoiceProcessingEnabled(true)"))
        let close = try XCTUnwrap(afterGate.range(of: "}"))
        XCTAssertLessThan(enable.lowerBound, close.lowerBound)
    }

    func testPlaybackStartHopsTheCompletionOntoTheMainQueue() throws {
        let body = try functionBody(
            named: "private func startPlayback",
            until: "private func stopCapture",
            in: pluginSource()
        )
        let start = try XCTUnwrap(body.range(of: "tap.start"))
        let afterStart = body[start.lowerBound...]
        let hop = try XCTUnwrap(afterStart.range(of: "DispatchQueue.main.async"))
        let assign = try XCTUnwrap(afterStart.range(of: "self.playbackTap"))
        XCTAssertLessThan(hop.lowerBound, assign.lowerBound)
    }

    func testMacOSSelectWritesTheVoiceProcessingInputElement() throws {
        let body = try functionBody(
            named: "static func select",
            until: "private static func devices",
            in: try string(at: "ux/macOS/AudioInputs+macOS.swift")
        )
        XCTAssertTrue(body.contains("isVoiceProcessingEnabled"))
        XCTAssertTrue(body.contains("kAudioUnitScope_Input"))
    }

    func testThePlaybackTapClosesItsSampleQueueBeforeStopReturns() throws {
        let source = try string(at: "ux/macOS/AudioPlayback+macOS.swift")
        let stop = try functionBody(
            named: "func stop()",
            until: "func stream(",
            in: source
        )
        let gate = try XCTUnwrap(stop.range(of: "samples.sync { stopped = true }"))
        let capture = try XCTUnwrap(stop.range(of: "stopCapture"))
        XCTAssertLessThan(gate.lowerBound, capture.lowerBound)

        let output = try functionBody(
            named: "didOutputSampleBuffer",
            until: "func stream(_ stream: SCStream, didStopWithError",
            in: source
        )
        XCTAssertTrue(output.contains("guard !stopped,"))
    }

    func testIOSListDoesNotUpgradeOrActivateTheSession() throws {
        let source = try string(
            at: "ux/iOS/AudioInputs+iOS.swift"
        )
        let list = try functionBody(
            named: "static func list()",
            until: "static func select",
            in: source
        )
        XCTAssertFalse(list.contains("upgradeForRecording()"))
        XCTAssertFalse(list.contains("setActive"))
        XCTAssertTrue(
            list.contains("setCategory(.playAndRecord, options: session.categoryOptions)")
        )
        let select = try functionBody(
            named: "static func select",
            until: "#endif",
            in: source
        )
        XCTAssertTrue(select.contains("upgradeForRecording()"))
    }

    private func pluginSource() throws -> String {
        try string(at: "ux/Audio/AudioCapturePlugin.swift")
    }

    private func string(at relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func functionBody(
        named: String,
        until: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: named))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: until))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
