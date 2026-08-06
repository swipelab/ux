import XCTest

@testable import ux_macos_core

final class ScreenSourcesWireTests: XCTestCase {
    private func listArguments(
        displays: [String] = ["1"],
        windows: [String] = ["5"],
        width: Int = 320,
        height: Int = 180
    ) -> [String: Any] {
        [
            "allowedDisplayIds": displays,
            "allowedWindowIds": windows,
            "thumbnailWidth": width,
            "thumbnailHeight": height,
        ]
    }

    private func item(
        kind: ScreenSourceKind = .window,
        id: String = "5",
        title: String = "Inbox",
        applicationName: String? = "Mail",
        width: Int = 1280,
        height: Int = 800,
        thumbnailPng: Data? = Data([137, 80, 78, 71])
    ) -> ScreenSourceSnapshotItem {
        ScreenSourceSnapshotItem(
            source: ScreenSource(
                kind: kind,
                id: id,
                title: title,
                applicationName: applicationName,
                width: width,
                height: height
            ),
            thumbnailPng: thumbnailPng
        )
    }

    func testTheBoolMethodsDecodeWithoutArguments() {
        XCTAssertEqual(
            ScreenSourcesWire.decode(method: "available", arguments: nil),
            .request(.available)
        )
        XCTAssertEqual(
            ScreenSourcesWire.decode(method: "hasPermission", arguments: nil),
            .request(.hasPermission)
        )
        XCTAssertEqual(
            ScreenSourcesWire.decode(method: "requestPermission", arguments: nil),
            .request(.requestPermission)
        )
    }

    func testListDecodesTheContractedArgumentMap() {
        let decoding = ScreenSourcesWire.decode(
            method: "list",
            arguments: listArguments(
                displays: ["1", "2"], windows: ["5"], width: 640, height: 360
            )
        )

        XCTAssertEqual(
            decoding,
            .request(
                .list(
                    allowedDisplayIds: ["1", "2"],
                    allowedWindowIds: ["5"],
                    thumbnailWidth: 640,
                    thumbnailHeight: 360
                )
            )
        )
    }

    func testEmptyAllowSetsDecodeToEmptySets() {
        let decoding = ScreenSourcesWire.decode(
            method: "list",
            arguments: listArguments(displays: [], windows: [])
        )

        XCTAssertEqual(
            decoding,
            .request(
                .list(
                    allowedDisplayIds: [],
                    allowedWindowIds: [],
                    thumbnailWidth: 320,
                    thumbnailHeight: 180
                )
            )
        )
    }

    func testAnUnknownMethodIsNotImplemented() {
        XCTAssertEqual(
            ScreenSourcesWire.decode(method: "thumbnails", arguments: nil),
            .unknownMethod
        )
    }

    func testMissingListArgumentsAreInvalid() {
        guard
            case .invalid(let failure) = ScreenSourcesWire.decode(
                method: "list", arguments: nil
            )
        else { return XCTFail("expected invalid") }

        XCTAssertEqual(failure.code, "invalid_response")
        XCTAssertEqual(failure.message, "arguments: missing")
    }

    func testEveryMistypedOrMissingListArgumentNamesItsField() {
        let wrongTypes: [String: Any] = [
            "allowedDisplayIds": "1",
            "allowedWindowIds": [5],
            "thumbnailWidth": "320",
            "thumbnailHeight": 180.5,
        ]

        for (field, value) in wrongTypes {
            var mistyped = listArguments()
            mistyped[field] = value
            var missing = listArguments()
            missing.removeValue(forKey: field)

            for arguments in [mistyped, missing] {
                guard
                    case .invalid(let failure) = ScreenSourcesWire.decode(
                        method: "list", arguments: arguments
                    )
                else { return XCTFail("expected invalid for \(field)") }

                XCTAssertEqual(failure.code, "invalid_response")
                XCTAssertEqual(failure.message?.hasPrefix("\(field):"), true)
            }
        }
    }

    func testEncodeCarriesExactlyTheContractedKeys() {
        let encoded = ScreenSourcesWire.encode([item()])

        XCTAssertEqual(
            Set(encoded[0].keys),
            [
                "id", "kind", "title", "applicationName", "sourceWidth",
                "sourceHeight", "thumbnailPng",
            ]
        )
        XCTAssertEqual(encoded[0]["id"] as? String, "5")
        XCTAssertEqual(encoded[0]["kind"] as? String, "window")
        XCTAssertEqual(encoded[0]["title"] as? String, "Inbox")
        XCTAssertEqual(encoded[0]["applicationName"] as? String, "Mail")
        XCTAssertEqual(encoded[0]["sourceWidth"] as? Int, 1280)
        XCTAssertEqual(encoded[0]["sourceHeight"] as? Int, 800)
        XCTAssertEqual(encoded[0]["thumbnailPng"] as? Data, Data([137, 80, 78, 71]))
    }

    func testEncodeSendsAbsentValuesAsNull() {
        let encoded = ScreenSourcesWire.encode(
            [item(kind: .display, id: "1", applicationName: nil, thumbnailPng: nil)]
        )

        XCTAssertEqual(encoded[0]["kind"] as? String, "display")
        XCTAssertTrue(encoded[0]["applicationName"] is NSNull)
        XCTAssertTrue(encoded[0]["thumbnailPng"] is NSNull)
    }

    func testEncodeKeepsSnapshotOrder() {
        let encoded = ScreenSourcesWire.encode([
            item(kind: .display, id: "1"),
            item(kind: .window, id: "5"),
            item(kind: .window, id: "6"),
        ])

        XCTAssertEqual(encoded.map { $0["id"] as? String }, ["1", "5", "6"])
    }

    func testEncodeOfAnEmptySnapshotIsAnEmptyList() {
        XCTAssertTrue(ScreenSourcesWire.encode([]).isEmpty)
    }
}
