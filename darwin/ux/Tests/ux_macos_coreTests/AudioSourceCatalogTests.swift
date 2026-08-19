import XCTest

@testable import ux_macos_core

final class AudioSourceCatalogTests: XCTestCase {
    private let inputs = [
        AudioInput(id: "uid-built-in", label: "MacBook Pro Microphone"),
        AudioInput(id: "uid-usb", label: "Scarlett Solo USB"),
    ]

    private func catalog(
        host: AudioHost = .macOS,
        playbackReady: Bool = true
    ) -> AudioSourceCatalog {
        AudioSourceCatalog(host: host, playbackReady: playbackReady)
    }

    func testMicrophonesComeBackInPlatformOrderAheadOfPlayback() {
        XCTAssertEqual(
            catalog().sources(inputs: inputs),
            [
                AudioSource(
                    id: "uid-built-in",
                    label: "MacBook Pro Microphone",
                    kind: .microphone
                ),
                AudioSource(
                    id: "uid-usb",
                    label: "Scarlett Solo USB",
                    kind: .microphone
                ),
                AudioSource(
                    id: "playback",
                    label: "Device playback",
                    kind: .playback
                ),
            ]
        )
    }

    func testTheWireShapeIsTheThreeStringFields() {
        XCTAssertEqual(
            catalog().sources(inputs: inputs).last?.wire,
            ["id": "playback", "label": "Device playback", "kind": "playback"]
        )
    }

    func testIOSListsNoPlaybackSourceEvenWhenTheHostReportsItReady() {
        let iOS = catalog(host: .iOS, playbackReady: true)

        XCTAssertEqual(
            iOS.sources(inputs: inputs).map(\.kind),
            [.microphone, .microphone]
        )
        XCTAssertEqual(iOS.selection(for: "playback", inputs: { self.inputs }), .unknown)
    }

    func testAHostWithoutTheTapListsNoPlaybackSource() {
        let unready = catalog(playbackReady: false)

        XCTAssertEqual(
            unready.sources(inputs: inputs).map(\.kind),
            [.microphone, .microphone]
        )
        XCTAssertEqual(
            unready.selection(for: "playback", inputs: { self.inputs }),
            .unknown
        )
    }

    func testNoSourceIdSelectsTheDefaultInputWithoutEnumerating() {
        var enumerated = false

        let selection = catalog().selection(for: nil, inputs: {
            enumerated = true
            return self.inputs
        })

        XCTAssertEqual(selection, .defaultInput)
        XCTAssertFalse(enumerated)
    }

    func testAMicrophoneIdSelectsThatInput() {
        XCTAssertEqual(
            catalog().selection(for: "uid-usb", inputs: { self.inputs }),
            .microphone(AudioInput(id: "uid-usb", label: "Scarlett Solo USB"))
        )
    }

    func testThePlaybackIdSelectsPlayback() {
        XCTAssertEqual(
            catalog().selection(for: "playback", inputs: { self.inputs }),
            .playback
        )
    }

    func testAnIdNamingNothingIsUnknown() {
        XCTAssertEqual(
            catalog().selection(for: "uid-unplugged", inputs: { self.inputs }),
            .unknown
        )
        XCTAssertEqual(catalog().selection(for: "", inputs: { self.inputs }), .unknown)
    }
}
