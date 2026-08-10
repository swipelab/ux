import CoreVideo
import Foundation
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
        completion: @escaping (Result<CVPixelBuffer, Error>) -> Void
    ) {
        do {
            try VNImageRequestHandler(cvPixelBuffer: input).perform([request])
            guard let mask = request.results?.first?.pixelBuffer else {
                return completion(.failure(PersonSegmentationFailure.noObservation))
            }
            completion(.success(mask))
        } catch {
            completion(.failure(error))
        }
    }
}
