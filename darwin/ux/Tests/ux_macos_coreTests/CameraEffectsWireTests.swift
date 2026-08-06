import XCTest

@testable import ux_macos_core

final class CameraEffectsWireTests: XCTestCase {
    func testAvailableDecodesWithoutArguments() {
        XCTAssertEqual(
            CameraEffectsWire.decode(method: "available", arguments: nil),
            .request(.available)
        )
    }

    func testSetEffectDecodesTheContractedArgumentMap() {
        XCTAssertEqual(
            CameraEffectsWire.decode(
                method: "setEffect",
                arguments: ["trackId": "t1", "effect": "blur", "generation": 7]
            ),
            .request(.setEffect(trackId: "t1", effect: .blur, generation: 7))
        )
        XCTAssertEqual(
            CameraEffectsWire.decode(
                method: "setEffect",
                arguments: ["trackId": "t1", "effect": "dim", "generation": 8]
            ),
            .request(.setEffect(trackId: "t1", effect: .dim, generation: 8))
        )
    }

    func testClearDecodesItsGeneration() {
        XCTAssertEqual(
            CameraEffectsWire.decode(method: "clear", arguments: ["generation": 3]),
            .request(.clear(generation: 3))
        )
    }

    func testASetEffectOffTheWireShapeNamesTheOffendingField() {
        let cases: [(String, [String: Any]?)] = [
            ("arguments", nil),
            ("trackId", ["effect": "blur", "generation": 1]),
            ("effect", ["trackId": "t1", "generation": 1]),
            ("effect", ["trackId": "t1", "effect": "sepia", "generation": 1]),
            ("effect", ["trackId": "t1", "effect": "none", "generation": 1]),
            ("generation", ["trackId": "t1", "effect": "blur"]),
        ]
        for (field, arguments) in cases {
            guard
                case .invalid(let failure) = CameraEffectsWire.decode(
                    method: "setEffect",
                    arguments: arguments
                )
            else {
                XCTFail("\(String(describing: arguments)) decoded")
                continue
            }
            XCTAssertEqual(failure.code, "invalid_response")
            XCTAssertTrue(
                failure.message?.hasPrefix("\(field):") == true,
                "\(String(describing: failure.message)) does not name \(field)"
            )
        }
    }

    func testAClearWithoutAGenerationIsInvalid() {
        guard
            case .invalid(let failure) = CameraEffectsWire.decode(
                method: "clear",
                arguments: [:]
            )
        else { return XCTFail("clear decoded without a generation") }
        XCTAssertEqual(failure.code, "invalid_response")
    }

    func testAnUnknownMethodIsNotImplemented() {
        XCTAssertEqual(
            CameraEffectsWire.decode(method: "setBackground", arguments: nil),
            .unknownMethod
        )
    }

    func testStatusEncodesToTheEventMap() {
        let applying = CameraEffectsWire.encode(.applying(.blur, generation: 4))
        XCTAssertEqual(applying["phase"] as? String, "applying")
        XCTAssertEqual(applying["effect"] as? String, "blur")
        XCTAssertEqual(applying["generation"] as? Int, 4)
        XCTAssertNil(applying["code"])

        let idle = CameraEffectsWire.encode(.idle(generation: 5))
        XCTAssertEqual(idle["phase"] as? String, "idle")
        XCTAssertEqual(idle["effect"] as? String, "none")
        XCTAssertNil(idle["code"])

        let active = CameraEffectsWire.encode(.active(.dim, generation: 6))
        XCTAssertEqual(active["phase"] as? String, "active")
        XCTAssertEqual(active["effect"] as? String, "dim")

        let failed = CameraEffectsWire.encode(
            .failed(.dim, generation: 6, code: "integration_unavailable")
        )
        XCTAssertEqual(failed["phase"] as? String, "failed")
        XCTAssertEqual(failed["code"] as? String, "integration_unavailable")
    }
}
