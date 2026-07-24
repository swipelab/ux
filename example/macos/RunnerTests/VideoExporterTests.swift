import AVFoundation
import FlutterMacOS
import XCTest

@testable import ux

/// Transform-export regression: a camera-style source whose
/// `preferredTransform` is a bare rotation (tx/ty = 0) must still land
/// its frames on the render canvas — the exporter anchors the upright
/// frame at the origin before composing the caller affine.
class VideoExporterTests: XCTestCase {
    func testTransformExportKeepsBareRotationFramesOnCanvas() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcUrl = dir.appendingPathComponent("src.mp4")
        let outPath = dir.appendingPathComponent("out.mp4").path
        try Self.writeGreenSource(
            to: srcUrl, width: 64, height: 32,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))

        let plugin = UxVideoExporterPlugin()
        let done = expectation(description: "export done")
        var donePayload: [String: Any]?
        _ = plugin.onListen(withArguments: nil) { event in
            guard let payload = event as? [String: Any] else { return }
            switch payload["type"] as? String {
            case "done":
                donePayload = payload
                done.fulfill()
            case "error":
                XCTFail("export failed: \(payload)")
                done.fulfill()
            default:
                break
            }
        }

        // Upright source is 32×64; export it 1:1 through the identity affine.
        plugin.handle(FlutterMethodCall(methodName: "start", arguments: [
            "sessionId": 1,
            "path": srcUrl.path,
            "outPath": outPath,
            "removeAudio": true,
            "transform": [1.0, 0, 0, 0, 1, 0, 0, 0, 1],
            "outWidth": 32,
            "outHeight": 64,
            "videoBitrate": 1_000_000,
        ])) { _ in }
        wait(for: [done], timeout: 30)

        XCTAssertEqual(donePayload?["path"] as? String, outPath)
        let pixel = try Self.centerPixel(ofFirstFrame: URL(fileURLWithPath: outPath))
        // yuv420 re-encode bleeds a little into r/b; black frames stay ~0.
        XCTAssertGreaterThan(pixel.g, 200, "exported frame lost the source video: \(pixel)")
        XCTAssertLessThan(pixel.r, 128, "exported frame lost the source video: \(pixel)")
        XCTAssertLessThan(pixel.b, 128, "exported frame lost the source video: \(pixel)")
    }

    private static func writeGreenSource(
        to url: URL, width: Int, height: Int, transform: CGAffineTransform
    ) throws {
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<8 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
            let buffer = pixelBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4] = 0        // B
                    row[x * 4 + 1] = 255  // G
                    row[x * 4 + 2] = 0    // R
                    row[x * 4 + 3] = 255  // A
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(
                buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        let finished = XCTestExpectation(description: "source written")
        writer.finishWriting { finished.fulfill() }
        XCTWaiter().wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private static func centerPixel(
        ofFirstFrame url: URL
    ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let image = try generator.copyCGImage(
            at: CMTime(value: 1, timescale: 30), actualTime: nil)
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        return (rgba[0], rgba[1], rgba[2])
    }
}
