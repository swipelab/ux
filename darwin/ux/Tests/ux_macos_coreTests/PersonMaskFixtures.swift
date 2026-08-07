import CoreGraphics
import CoreVideo
import Foundation

@testable import ux_macos_core

struct ScriptedSegmenterFailure: Error {}

final class TestClock: CameraEffectsClock {
    private let mutex = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        mutex.lock()
        defer { mutex.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        mutex.lock()
        value += seconds
        mutex.unlock()
    }
}

/// A segmenter the tests drive: it answers at once, fails, holds its answer,
/// blocks its caller until released, or spends time on the injected clock.
final class ScriptedSegmenter: PersonSegmenting {
    enum Behavior {
        case immediate
        case failing
        case deferred
        case blocked
        case advancing(TimeInterval)
    }

    init(
        _ behavior: Behavior = .immediate,
        clock: TestClock? = nil,
        mask: @escaping () -> CVPixelBuffer = {
            makeMaskBuffer(
                width: 256, height: 192,
                person: CGRect(x: 64, y: 48, width: 128, height: 96)
            )
        }
    ) {
        stored = behavior
        self.clock = clock
        self.mask = mask
    }

    let quality = PersonMaskQuality.fast

    private let clock: TestClock?
    private let mask: () -> CVPixelBuffer
    private let state = NSCondition()
    private var stored: Behavior
    private var submitCount = 0
    private var finishCount = 0
    /// Sizes, not buffers: holding the inputs would keep the producer's whole
    /// pool checked out.
    private var inputSizes: [(width: Int, height: Int)] = []
    private var releasing = false
    private var held: [(Result<CVPixelBuffer, Error>) -> Void] = []

    var behavior: Behavior {
        get {
            state.lock()
            defer { state.unlock() }
            return stored
        }
        set {
            state.lock()
            stored = newValue
            state.unlock()
        }
    }

    var submits: Int {
        state.lock()
        defer { state.unlock() }
        return submitCount
    }

    var inputs: [(width: Int, height: Int)] {
        state.lock()
        defer { state.unlock() }
        return inputSizes
    }

    func submit(
        _ input: CVPixelBuffer,
        completion: @escaping (Result<CVPixelBuffer, Error>) -> Void
    ) {
        state.lock()
        submitCount += 1
        inputSizes.append(
            (CVPixelBufferGetWidth(input), CVPixelBufferGetHeight(input))
        )
        let behavior = stored
        state.broadcast()
        state.unlock()

        switch behavior {
        case .immediate:
            completion(.success(mask()))
        case .failing:
            completion(.failure(ScriptedSegmenterFailure()))
        case .deferred:
            state.lock()
            held.append(completion)
            state.unlock()
        case .blocked:
            state.lock()
            while !releasing { state.wait() }
            state.unlock()
            completion(.success(mask()))
        case .advancing(let seconds):
            clock?.advance(seconds)
            completion(.success(mask()))
        }

        state.lock()
        finishCount += 1
        state.broadcast()
        state.unlock()
    }

    /// Lets every blocked and future submission answer.
    func release() {
        state.lock()
        releasing = true
        state.broadcast()
        state.unlock()
    }

    func answerHeld() {
        state.lock()
        let pending = held
        held = []
        state.unlock()
        for completion in pending { completion(.success(mask())) }
    }

    @discardableResult
    func waitForSubmits(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) { self.submitCount >= count }
    }

    @discardableResult
    func waitForFinishes(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        wait(timeout: timeout) { self.finishCount >= count }
    }

    private func wait(timeout: TimeInterval, until reached: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while !reached() {
            if !state.wait(until: deadline) { return false }
        }
        return true
    }
}
