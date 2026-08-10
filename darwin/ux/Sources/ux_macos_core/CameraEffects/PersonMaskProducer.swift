import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import os

/// The quality level a segmenter runs at. Each answers on a fixed grid whose
/// aspect does not track the input's: 256x192 at `.fast`, 512x384 at
/// `.balanced`, 2016x1512 at `.accurate`.
public enum PersonMaskQuality: String, Equatable, Sendable {
    case fast
    case balanced
    case accurate
}

/// Person segmentation over one ux-owned input buffer, answering through the
/// completion when the inference finishes.
public protocol PersonSegmenting: AnyObject {
    var quality: PersonMaskQuality { get }

    /// Called on the producer's serial queue, one submission at a time.
    func submit(
        _ input: CVPixelBuffer,
        completion: @escaping (Result<CVPixelBuffer, Error>) -> Void
    )
}

/// Keeps one person mask current for the compositor to pull: an eligible
/// frame's crop is downscaled into a ux-owned buffer and handed to one serial
/// queue, and the newest generation-matched result is published.
public final class PersonMaskProducer {
    /// The inference input's size, in the frame's unrotated pixel space.
    public static let inputWidth = 256
    public static let inputHeight = 144

    /// One buffer for the inference in flight, one for work `reset` abandoned
    /// while it is still held.
    public static let inputBufferCount = 2

    public static let targetSubmissionsPerSecond = 15.0
    public static let targetSubmissionInterval = 1.0 / targetSubmissionsPerSecond

    public init(
        segmenter: PersonSegmenting,
        pools: CameraEffectBufferPools = PixelBufferPools(
            threshold: PersonMaskProducer.inputBufferCount
        ),
        clock: CameraEffectsClock = UptimeClock()
    ) {
        self.segmenter = segmenter
        self.clock = clock
        pool = pools.makePool(width: Self.inputWidth, height: Self.inputHeight)
        // Caching intermediates would hold the camera's buffer past the frame
        // callback that lent it.
        context = CIContext(
            mtlDevice: MTLCreateSystemDefaultDevice()!,
            options: [
                .workingColorSpace: NSNull(),
                .cacheIntermediates: false,
            ]
        )
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private let segmenter: PersonSegmenting
    private let clock: CameraEffectsClock
    private let pool: CameraEffectBufferPool?
    private let context: CIContext
    let queue = DispatchQueue(
        label: "com.swipelab.ux.person-mask", qos: .userInitiated
    )
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var published: CameraMask?
    private var inFlight = false
    private var generation = 0
    private var submittedAt: TimeInterval = 0
    private var lastSubmissionAt: TimeInterval?
    private var interval = PersonMaskProducer.targetSubmissionInterval
    private var publications = 0

    public var mask: CameraMask? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return published
    }

    var submissionInterval: TimeInterval {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return interval
    }

    /// Takes what this frame owes the next mask and returns; it never waits on
    /// an inference and never retains the frame's buffer.
    public func consider(_ frame: CameraFrame) {
        guard let claimed = claim() else { return }
        guard
            frame.crop.width > 0, frame.crop.height > 0,
            let pool, let destination = pool.takeBuffer(),
            copy(frame, into: destination)
        else { return release(claimed) }
        guard let submission = stamp(frame, claimed) else { return }
        queue.async { [segmenter, weak self] in
            segmenter.submit(destination) { result in
                self?.complete(result, submission)
            }
        }
    }

    /// Retires every mask and submission of the effect that ends here. Work
    /// still inside the segmenter is abandoned rather than waited on.
    public func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        generation += 1
        published = nil
        inFlight = false
        lastSubmissionAt = nil
        interval = Self.targetSubmissionInterval
    }

    private struct Submission {
        let generation: Int
        let crop: CGRect
        let timestampNs: Int64
    }

    /// The generation the caller may submit under, or `nil` when an inference
    /// is in flight or the cadence gate has not opened.
    private func claim() -> Int? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard !inFlight else { return nil }
        if let lastSubmissionAt, clock.now - lastSubmissionAt < interval { return nil }
        inFlight = true
        return generation
    }

    private func release(_ claimed: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard claimed == generation else { return }
        inFlight = false
    }

    private func stamp(_ frame: CameraFrame, _ claimed: Int) -> Submission? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard claimed == generation else { return nil }
        submittedAt = clock.now
        lastSubmissionAt = submittedAt
        return Submission(
            generation: claimed, crop: frame.crop, timestampNs: frame.timestampNs
        )
    }

    private func complete(
        _ result: Result<CVPixelBuffer, Error>, _ submission: Submission
    ) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard submission.generation == generation else { return }
        inFlight = false
        guard case .success(let buffer) = result else { return }
        published = CameraMask(
            pixelBuffer: buffer,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            sourceRect: submission.crop,
            sourceTimestampNs: submission.timestampNs
        )
        publications += 1
        // The first inference of a producer carries the model load, which is
        // two orders of magnitude slower than a warm one.
        guard publications > 1 else { return }
        interval = max(Self.targetSubmissionInterval, clock.now - submittedAt)
    }

    private func copy(_ frame: CameraFrame, into destination: CVPixelBuffer) -> Bool {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        // Crop arrives in the buffer's top-left-origin space; Core Image works
        // bottom-left.
        let cropRect = CGRect(
            x: frame.crop.minX,
            y: CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer)) - frame.crop.maxY,
            width: frame.crop.width,
            height: frame.crop.height
        )
        let bounds = CGRect(
            x: 0, y: 0, width: Self.inputWidth, height: Self.inputHeight
        )
        let image =
            source
            .cropped(to: cropRect)
            .transformed(
                by: CGAffineTransform(
                    translationX: -cropRect.minX, y: -cropRect.minY
                )
            )
            .transformed(
                by: CGAffineTransform(
                    scaleX: bounds.width / cropRect.width,
                    y: bounds.height / cropRect.height
                )
            )
        let target = CIRenderDestination(pixelBuffer: destination)
        target.colorSpace = nil
        do {
            let task = try context.startTask(
                toRender: image, from: bounds, to: target, at: .zero
            )
            try task.waitUntilCompleted()
        } catch {
            return false
        }
        return true
    }
}
