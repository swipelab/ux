import CoreVideo
import Foundation
import ImageIO
import Vision

/// Why an inference produced no mask.
public enum PersonSegmentationFailure: Error, Equatable {
    case noObservation
}

/// ``PersonSegmenting`` over Vision's person segmentation.
@available(macOS 12, iOS 15, *)
public final class VisionPersonSegmenter: PersonSegmenting {
    public init() {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    public let quality = PersonMaskQuality.fast

    /// One request across every inference: it holds the loaded model, and a
    /// fresh one loads it again.
    private let request: VNGeneratePersonSegmentationRequest

    public func submit(
        _ input: CVPixelBuffer,
        rotation: CameraFrameRotation,
        completion: @escaping (Result<CVPixelBuffer, Error>) -> Void
    ) {
        do {
            try VNImageRequestHandler(
                cvPixelBuffer: input, orientation: Self.orientation(rotation)
            ).perform([request])
            guard let mask = request.results?.first?.pixelBuffer else {
                return completion(.failure(PersonSegmentationFailure.noObservation))
            }
            completion(.success(mask))
        } catch {
            completion(.failure(error))
        }
    }

    static func orientation(
        _ rotation: CameraFrameRotation
    ) -> CGImagePropertyOrientation {
        switch rotation {
        case .degrees0: return .up
        case .degrees90: return .right
        case .degrees180: return .down
        case .degrees270: return .left
        }
    }
}
