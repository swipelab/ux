import Foundation

/// Why a considered frame did not open a submission.
public enum CameraMaskRefusal: String, Equatable, Sendable {
    /// An inference held the producer.
    case inFlight

    /// The cadence gate had not opened since the last submission.
    case cadence
}

/// What closed a submission short of a publication.
public enum CameraMaskFailure: Equatable, Sendable {
    /// The frame's crop, the buffer pool or the downscale denied the
    /// inference an input.
    case input

    /// The effect the submission belonged to was retired before it answered.
    case retired

    /// The inference answered with this error.
    case inference(String)
}

/// One submission's course through the producer, from the claim that opened it
/// to the completion that closed it. A stage the submission has not reached
/// carries nil.
public struct CameraMaskSubmission: Equatable, Sendable {
    public let sequence: Int

    /// The capture timestamp of the frame the submission was made from, in
    /// ``CameraCompositeRecord/frameTimestampNs``'s domain.
    public let frameTimestampNs: Int64

    /// The cadence gate in force when the claim opened.
    public let interval: TimeInterval

    public let claimedAt: TimeInterval

    /// When the downscaled copy landed and the queue hop was dispatched.
    public var submittedAt: TimeInterval?

    /// When the serial queue handed the submission to the segmenter.
    public var enteredAt: TimeInterval?

    public var closedAt: TimeInterval?

    public var publishedAt: TimeInterval?

    public var failure: CameraMaskFailure?
}

/// What the producer made of the frames it was given: the submissions the log
/// still holds, oldest first, and totals over every frame since the process
/// started. Reading takes nothing out.
public struct CameraMaskTelemetry: Equatable, Sendable {
    public let submissions: [CameraMaskSubmission]
    public let considered: Int
    public let refusedInFlight: Int
    public let refusedCadence: Int
    public let inputFailures: Int
    public let inferenceFailures: Int
    public let publications: Int
    public let lastConsideredAt: TimeInterval?

    /// The clock reading the snapshot was taken at, which every other time in
    /// it is measured against.
    public let readAt: TimeInterval
}

/// The mask submissions the rig can still read. A submission leaves only once
/// ``capacity`` later ones sit on top of it, and the totals count every frame
/// whether or not its submission is still held. A log built with `exposes`
/// false keeps nothing and counts nothing.
public final class CameraMaskLog {
    public static let capacity = 256

    public init(exposes: Bool, capacity: Int = CameraMaskLog.capacity) {
        self.exposes = exposes
        self.capacity = capacity
    }

    /// Whether the log keeps what it is given, and so whether a producer
    /// feeding it spends anything on accounting.
    public let exposes: Bool

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [CameraMaskSubmission] = []
    private var next = 0
    private var considered = 0
    private var refusedInFlight = 0
    private var refusedCadence = 0
    private var inputFailures = 0
    private var inferenceFailures = 0
    private var publications = 0
    private var lastConsideredAt: TimeInterval?

    public func telemetry(at readAt: TimeInterval) -> CameraMaskTelemetry {
        lock.lock()
        defer { lock.unlock() }
        return CameraMaskTelemetry(
            submissions: entries,
            considered: considered,
            refusedInFlight: refusedInFlight,
            refusedCadence: refusedCadence,
            inputFailures: inputFailures,
            inferenceFailures: inferenceFailures,
            publications: publications,
            lastConsideredAt: lastConsideredAt,
            readAt: readAt
        )
    }

    func considered(at instant: TimeInterval) {
        guard exposes else { return }
        lock.lock()
        considered += 1
        lastConsideredAt = instant
        lock.unlock()
    }

    func refused(_ refusal: CameraMaskRefusal) {
        guard exposes else { return }
        lock.lock()
        switch refusal {
        case .inFlight: refusedInFlight += 1
        case .cadence: refusedCadence += 1
        }
        lock.unlock()
    }

    /// Opens a submission and answers the sequence every later stage names it
    /// by. A log that keeps nothing answers a sequence no stage matches.
    func claimed(
        frameTimestampNs: Int64, interval: TimeInterval, at instant: TimeInterval
    ) -> Int {
        guard exposes else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        let sequence = next
        next += 1
        if entries.count == capacity { entries.removeFirst() }
        entries.append(
            CameraMaskSubmission(
                sequence: sequence,
                frameTimestampNs: frameTimestampNs,
                interval: interval,
                claimedAt: instant
            )
        )
        return sequence
    }

    func submitted(_ sequence: Int, at instant: TimeInterval) {
        update(sequence) { $0.submittedAt = instant }
    }

    func entered(_ sequence: Int, at instant: TimeInterval) {
        update(sequence) { $0.enteredAt = instant }
    }

    func closed(_ sequence: Int, _ failure: CameraMaskFailure, at instant: TimeInterval) {
        guard exposes else { return }
        lock.lock()
        switch failure {
        case .input: inputFailures += 1
        case .inference: inferenceFailures += 1
        case .retired: break
        }
        if let index = index(of: sequence) {
            entries[index].closedAt = instant
            entries[index].failure = failure
        }
        lock.unlock()
    }

    func published(_ sequence: Int, at instant: TimeInterval) {
        guard exposes else { return }
        lock.lock()
        publications += 1
        if let index = index(of: sequence) {
            entries[index].closedAt = instant
            entries[index].publishedAt = instant
        }
        lock.unlock()
    }

    private func update(
        _ sequence: Int, _ change: (inout CameraMaskSubmission) -> Void
    ) {
        guard exposes else { return }
        lock.lock()
        if let index = index(of: sequence) { change(&entries[index]) }
        lock.unlock()
    }

    private func index(of sequence: Int) -> Int? {
        guard let first = entries.first else { return nil }
        let index = sequence - first.sequence
        return entries.indices.contains(index) ? index : nil
    }
}
