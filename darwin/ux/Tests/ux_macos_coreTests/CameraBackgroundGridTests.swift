import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

private let size = CameraBackgroundGrid.size

final class CameraBackgroundGridTests: XCTestCase {
    private func grid(
        _ effect: CameraEffect,
        width: Int,
        height: Int,
        mask: CameraMask?,
        rejection: CameraMaskRejection? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CameraBackgroundGrid {
        let compositor = CameraEffectCompositor(effect: effect, measures: true)
        let frame = makeEffectFrame(width: width, height: height) { x, y in
            UInt8((x * 7 + y * 13) % 256)
        }

        let outcome = compositor.composite(frame: frame, mask: mask)

        guard case .composited(_, let background, let maskRejection) = outcome else {
            XCTFail("expected a composited frame", file: file, line: line)
            throw CompositeExpectation.notComposited
        }
        XCTAssertEqual(maskRejection, rejection, file: file, line: line)
        return try XCTUnwrap(background, file: file, line: line)
    }

    private enum CompositeExpectation: Error {
        case notComposited
    }

    private func uniform(_ fraction: Float) -> [Float] {
        [Float](repeating: fraction, count: CameraBackgroundGrid.cells)
    }

    private func cells(_ grid: CameraBackgroundGrid) -> [Float] {
        (0..<CameraBackgroundGrid.cells).map {
            grid.fraction(column: $0 % size, row: $0 / size)
        }
    }

    private func assertCells(
        _ measured: CameraBackgroundGrid,
        _ expected: [Float],
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (cell, fraction) in cells(measured).enumerated() {
            XCTAssertEqual(
                fraction, expected[cell], accuracy: accuracy,
                "cell (\(cell % size),\(cell / size))", file: file, line: line
            )
        }
    }

    func testAMaskOverEveryPixelLeavesNoBackgroundInAnyCell() throws {
        let mask = makeEffectMask(
            width: 40,
            height: 24,
            sourceRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            person: CGRect(x: 0, y: 0, width: 40, height: 24)
        )

        let measured = try grid(.blur, width: 320, height: 180, mask: mask)

        assertCells(measured, uniform(0), accuracy: 0.004)
    }

    func testWithoutAMaskEveryCellIsWhollyBackground() throws {
        let measured = try grid(.blur, width: 320, height: 180, mask: nil)

        XCTAssertEqual(cells(measured), uniform(1))
    }

    func testAMaskCoveringNothingIsSetAsideAndEveryCellIsWhollyBackground() throws {
        let mask = makeEffectMask(
            width: 40,
            height: 24,
            sourceRect: CGRect(x: 0, y: 0, width: 320, height: 180)
        )

        let measured = try grid(
            .dim, width: 320, height: 180, mask: mask, rejection: .empty
        )

        XCTAssertEqual(cells(measured), uniform(1))
    }

    func testAFrameNoMultipleOfTheGridSplitsItsPixelsIntoWholeCells() {
        let edges = (0...size).map { CameraBackgroundGrid.edge($0, over: 37) }

        XCTAssertEqual(
            edges, [0, 2, 4, 6, 9, 11, 13, 16, 18, 20, 23, 25, 27, 30, 32, 34, 37]
        )
    }

    func testACompositorMeasuringNothingReportsNoGrid() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(width: 320, height: 180)

        let outcome = compositor.composite(frame: frame, mask: nil)

        XCTAssertNil(outcome.background)
    }

    /// Dimming a 255 frame leaves person 255 over a halved background, so each
    /// output luma pins its pixel's alpha and a cell's emitted mean carries the
    /// fraction the grid reports.
    func testEveryCellsFractionMatchesTheLumaTheCompositeEmitted() throws {
        let width = 320
        let height = 180
        let compositor = CameraEffectCompositor(effect: .dim, measures: true)
        let frame = makeEffectFrame(width: width, height: height) { _, _ in 255 }
        let mask = makeEffectMask(
            width: 40,
            height: 24,
            sourceRect: CGRect(x: 0, y: 0, width: width, height: height),
            person: CGRect(x: 11, y: 6, width: 17, height: 11)
        )

        let outcome = compositor.composite(frame: frame, mask: mask)

        guard case .composited(let output, let background, _) = outcome else {
            return XCTFail("expected a composited frame")
        }
        let measured = try XCTUnwrap(background)
        let effected = Float(grayValue(output.pixelBuffer, 0, 0))
        for row in 0..<size {
            let rows =
                CameraBackgroundGrid.edge(row, over: height)
                ..< CameraBackgroundGrid.edge(row + 1, over: height)
            for column in 0..<size {
                let columns =
                    CameraBackgroundGrid.edge(column, over: width)
                    ..< CameraBackgroundGrid.edge(column + 1, over: width)
                var sum = 0
                var pixels = 0
                for y in rows {
                    for x in columns {
                        sum += grayValue(output.pixelBuffer, x, y)
                        pixels += 1
                    }
                }
                let emitted = Float(sum) / Float(pixels)
                XCTAssertEqual(
                    measured.fraction(column: column, row: row),
                    (255 - emitted) / (255 - effected),
                    accuracy: 0.004,
                    "cell (\(column),\(row)) emitted \(emitted)"
                )
            }
        }
    }
}
