import Foundation

/// How much of the composite each cell of a ``size``-square grid over the frame
/// took from the effect: the mean, over the cell's pixels, of the background
/// weight the blend applied — 1 where the effect covered the cell whole and 0
/// where the person did.
///
/// Cells are half-open pixel rectangles that partition the frame; a cell no
/// pixel falls in holds 0.
public struct CameraBackgroundGrid: Equatable, Sendable {
    public static let size = 16
    public static let cells = size * size

    /// The first pixel of cell `index` along an axis `extent` pixels long.
    public static func edge(_ index: Int, over extent: Int) -> Int {
        index * extent / size
    }

    public init(_ fractions: [Float]) {
        precondition(fractions.count == Self.cells)
        self.fractions = fractions
    }

    public init(repeating fraction: Float) {
        fractions = [Float](repeating: fraction, count: Self.cells)
    }

    private let fractions: [Float]

    public func fraction(column: Int, row: Int) -> Float {
        fractions[row * Self.size + column]
    }
}

/// The processor's classification of its mask snapshot for one published frame.
public enum CameraCompositeUse: Equatable, Sendable {
    /// The snapshot passes the structural applicability predicate.
    case used

    /// The mask is structurally inapplicable to the frame.
    case rejected(CameraMaskRejection)

    /// No render happened; the frame published a substitute.
    case substituted(CameraCompositeSubstitution)

    /// The processor held no mask when the frame arrived.
    case maskless
}

/// One published-frame record keyed by `generation` and `frameTimestampNs`.
public struct CameraCompositeRecord: Equatable, Sendable {
    public init(
        generation: Int,
        frameTimestampNs: Int64,
        maskFrameTimestampNs: Int64?,
        use: CameraCompositeUse,
        background: CameraBackgroundGrid?
    ) {
        self.generation = generation
        self.frameTimestampNs = frameTimestampNs
        self.maskFrameTimestampNs = maskFrameTimestampNs
        self.use = use
        self.background = background
    }

    public let generation: Int
    public let frameTimestampNs: Int64

    /// The timestamp of the frame the mask was inferred from, if there was one.
    public let maskFrameTimestampNs: Int64?

    public let use: CameraCompositeUse

    /// Absent when the frame published a substitute rather than a render, and
    /// when its compositor measures nothing.
    public let background: CameraBackgroundGrid?
}

/// The composites the rig can still read, oldest first. Reading takes nothing
/// out, so a window widened after the fact still finds its records; a record
/// leaves only once ``capacity`` later ones sit on top of it. A log built with
/// `exposes` false keeps nothing at all.
public final class CameraCompositeLog {
    public static let capacity = 512

    public init(exposes: Bool, capacity: Int = CameraCompositeLog.capacity) {
        self.exposes = exposes
        self.capacity = capacity
    }

    /// Whether the log keeps what it is given, and so whether a compositor
    /// feeding it measures a background at all.
    public let exposes: Bool

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [CameraCompositeRecord] = []

    public func record(_ record: CameraCompositeRecord) {
        guard exposes else { return }
        lock.lock()
        if entries.count == capacity { entries.removeFirst() }
        entries.append(record)
        lock.unlock()
    }

    public func records() -> [CameraCompositeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
