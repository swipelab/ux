import Foundation

/// Serves `ux/camera_effects`: one effected track at a time, commands one at a
/// time, and the status the event channel reports.
///
/// Every Flutter-facing continuation — the status observer and a withheld
/// command completion, which resolves from a callback arriving on the bridge's
/// capture thread — leaves through `delivery`, so the plugin above marshals
/// nothing.
public final class CameraEffectsService {
    /// A `nil` `processors` is a host below the capability's floor.
    public init(
        processors: CameraEffectProcessorFactory?,
        scheduler: CameraEffectsScheduling,
        delivery: CameraEffectsDelivering = MainQueueDelivery()
    ) {
        self.processors = processors
        self.scheduler = scheduler
        self.delivery = delivery
    }

    /// The window an attach has to see its first frame, and the window
    /// `applying` has — from that frame, or from an accepted same-track
    /// switch — to see a composited output.
    static let commandDeadline: TimeInterval = 0.75

    /// The span an unbroken run of substituted frames may cover before an
    /// active effect counts as failing. A pool exhausted behind a busy encoder
    /// answers with substitutes until any of its
    /// `PixelBufferPool.allocationThreshold` buffers comes back, so isolated
    /// substitutions are backpressure; a run covering this span holds the
    /// whole pool for several times its own depth at capture rate. It is the
    /// window `commandDeadline` gives an applying effect to produce its first
    /// composite.
    static let sustainedSubstitution: TimeInterval = commandDeadline

    private let processors: CameraEffectProcessorFactory?
    private let scheduler: CameraEffectsScheduling
    private let delivery: CameraEffectsDelivering

    private let lock = NSLock()
    private var bridge: CameraTrackBridging?
    private var attached: Attached?
    private var withheld: Withheld?
    private var observer: ((CameraEffectStatus) -> Void)?
    private var status = CameraEffectStatus.idle(generation: 0)
    private var lastGeneration = 0
    private var serving = false
    private var queued: [(Command, Completion)] = []

    // MARK: - Bridge

    public var isBridgeInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bridge != nil
    }

    /// A live attachment is detached through the outgoing bridge, which owns
    /// its registration, before the new bridge is stored.
    public func install(_ bridge: CameraTrackBridging) {
        lock.lock()
        let outgoing = self.bridge
        let record = attached
        let handle = record?.handle
        let applying = record?.applyingDeadline
        record?.applyingDeadline = nil
        record?.handle = nil
        attached = nil
        lock.unlock()

        applying?.cancel()
        if let handle, let outgoing { outgoing.detach(handle) }
        record?.currentProcessor().retire()

        lock.lock()
        self.bridge = bridge
        lock.unlock()
    }

    /// Drops the bridge. A live attachment is detached through it, then the
    /// bridge is told to release the rest, and the attachment is reported once
    /// as a failure; a withheld reply resolves immediately rather than waiting
    /// out its deadline.
    public func uninstall() {
        lock.lock()
        let outgoing = bridge
        bridge = nil
        let record = attached
        let handle = record?.handle
        let applying = record?.applyingDeadline
        record?.applyingDeadline = nil
        record?.handle = nil
        let pending = withheld
        attached = nil
        withheld = nil
        let observer = self.observer
        var event: CameraEffectStatus?
        if pending != nil {
            event = .idle(generation: lastGeneration)
        } else if let record {
            event = .failed(
                record.effect,
                generation: lastGeneration,
                code: CameraEffectsFailure.integrationUnavailable.code
            )
        }
        if let event { status = event }
        lock.unlock()

        pending?.deadline.cancel()
        applying?.cancel()
        if let outgoing, record != nil {
            if let handle { outgoing.detach(handle) }
            outgoing.teardown()
        }
        record?.currentProcessor().retire()
        if let event { emit(event, to: observer) }
        if let pending {
            finish(.failure(.integrationUnavailable), pending.completion)
        }
    }

    // MARK: - Status

    public var currentStatus: CameraEffectStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    public func setStatusObserver(_ observer: ((CameraEffectStatus) -> Void)?) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    // MARK: - Commands

    public func reply(
        to request: CameraEffectsRequest,
        completion: @escaping Completion
    ) {
        switch request {
        case .available:
            lock.lock()
            let capable = bridge != nil && processors != nil
            lock.unlock()
            delivery.deliver { completion(.flag(capable)) }
        case .setEffect(let trackId, let effect, let generation):
            serve(.setEffect(trackId, effect, generation), completion)
        case .clear(let generation):
            serve(.clear(generation), completion)
        }
    }

    /// Detaches, clears the observer and releases the handle.
    public func teardown() {
        lock.lock()
        observer = nil
        let record = attached
        let handle = record?.handle
        let applying = record?.applyingDeadline
        record?.applyingDeadline = nil
        let pending = withheld
        let bridge = self.bridge
        attached = nil
        withheld = nil
        queued.removeAll()
        serving = false
        lock.unlock()

        pending?.deadline.cancel()
        applying?.cancel()
        if let handle, let bridge { bridge.detach(handle) }
        record?.currentProcessor().retire()
        if let pending {
            delivery.deliver { pending.completion(.failure(.integrationUnavailable)) }
        }
    }

    public typealias Completion = (CameraEffectsReply) -> Void

    // MARK: - Serialization

    private enum Command {
        case setEffect(String, CameraEffect, Int)
        case clear(Int)
    }

    private func serve(_ command: Command, _ completion: @escaping Completion) {
        lock.lock()
        if serving {
            queued.append((command, completion))
            lock.unlock()
            return
        }
        serving = true
        lock.unlock()
        run(command, completion)
    }

    private func run(_ command: Command, _ completion: @escaping Completion) {
        switch command {
        case .setEffect(let trackId, let effect, let generation):
            setEffect(
                trackId: trackId,
                effect: effect,
                generation: generation,
                completion: completion
            )
        case .clear(let generation):
            clear(generation: generation, completion: completion)
        }
    }

    private func finish(_ reply: CameraEffectsReply, _ completion: @escaping Completion) {
        delivery.deliver { completion(reply) }
        lock.lock()
        guard !queued.isEmpty else {
            serving = false
            lock.unlock()
            return
        }
        let next = queued.removeFirst()
        lock.unlock()
        run(next.0, next.1)
    }

    // MARK: - setEffect

    private func setEffect(
        trackId: String,
        effect: CameraEffect,
        generation: Int,
        completion: @escaping Completion
    ) {
        lock.lock()
        lastGeneration = generation
        lock.unlock()

        guard let processors else {
            return finish(.failure(.unsupported), completion)
        }
        let processor: CameraEffectProcessor
        do {
            processor = try processors.makeProcessor(for: effect)
        } catch {
            return finish(.failure(.initializationFailed), completion)
        }

        lock.lock()
        guard let bridge else {
            lock.unlock()
            return finish(.failure(.integrationUnavailable), completion)
        }
        let observer = self.observer
        let applying = CameraEffectStatus.applying(effect, generation: generation)
        status = applying

        if let current = attached, current.trackId == trackId {
            current.effect = effect
            current.activated = false
            current.failed = false
            current.substitution.end()
            let outgoing = current.adopt(processor)
            armApplyingDeadline(current)
            lock.unlock()
            outgoing.retire()
            emit(applying, to: observer)
            return finish(.done, completion)
        }

        let previous = attached
        let previousDeadline = previous?.applyingDeadline
        previous?.applyingDeadline = nil
        let record = Attached(trackId: trackId, effect: effect, processor: processor)
        attached = record
        let deadline = scheduler.schedule(after: Self.commandDeadline) {
            [weak self, weak record] in
            guard let record else { return }
            self?.deadlineElapsed(record)
        }
        withheld = Withheld(record: record, deadline: deadline, completion: completion)
        lock.unlock()

        emit(applying, to: observer)
        previousDeadline?.cancel()
        if let previous {
            if let handle = previous.handle { bridge.detach(handle) }
            previous.currentProcessor().retire()
        }

        do {
            let handle = try bridge.attach(
                trackId: trackId,
                processing: { [weak self] frame in
                    self?.callbackEntered(record)
                    let outcome = record.process(frame)
                    self?.frameProcessed(record, outcome)
                    return outcome.frame
                }
            )
            lock.lock()
            if attached === record { record.handle = handle }
            lock.unlock()
        } catch {
            attachFailed(record, Self.failure(for: error))
        }
    }

    private static func failure(for error: Error) -> CameraEffectsFailure {
        error as? CameraTrackAttachFailure == .unknownTrack
            ? .trackNotFound
            : .initializationFailed
    }

    /// Retracts a command that emitted `applying` and left nothing attached.
    private func attachFailed(_ record: Attached, _ failure: CameraEffectsFailure) {
        lock.lock()
        guard let pending = withheld, pending.record === record else {
            lock.unlock()
            return
        }
        withheld = nil
        if attached === record { attached = nil }
        let idle = CameraEffectStatus.idle(generation: lastGeneration)
        status = idle
        let observer = self.observer
        lock.unlock()

        pending.deadline.cancel()
        record.currentProcessor().retire()
        emit(idle, to: observer)
        finish(.failure(failure), pending.completion)
    }

    private func deadlineElapsed(_ record: Attached) {
        lock.lock()
        guard let pending = withheld, pending.record === record else {
            lock.unlock()
            return
        }
        withheld = nil
        if attached === record { attached = nil }
        let handle = record.handle
        let bridge = self.bridge
        let idle = CameraEffectStatus.idle(generation: lastGeneration)
        status = idle
        let observer = self.observer
        lock.unlock()

        if let handle, let bridge { bridge.detach(handle) }
        record.currentProcessor().retire()
        emit(idle, to: observer)
        finish(.failure(.trackNotProcessable), pending.completion)
    }

    /// The first frame on an attachment: the attach guard is satisfied and
    /// the withheld reply resolves, while activation waits for a composited
    /// output under the applying deadline armed here.
    private func callbackEntered(_ record: Attached) {
        lock.lock()
        guard attached === record, !record.entered else {
            lock.unlock()
            return
        }
        record.entered = true
        var pending = withheld
        if pending?.record === record {
            withheld = nil
        } else {
            pending = nil
        }
        armApplyingDeadline(record)
        lock.unlock()

        pending?.deadline.cancel()
        if let pending { finish(.done, pending.completion) }
    }

    /// Bounds applying→active. The deadline carries the processor whose
    /// composite must resolve it, so one armed for a retired processor cannot
    /// tear down its successor's command on the same record.
    private func armApplyingDeadline(_ record: Attached) {
        record.applyingDeadline?.cancel()
        let processor = record.currentProcessor()
        record.applyingDeadline = scheduler.schedule(after: Self.commandDeadline) {
            [weak self, weak record, weak processor] in
            guard let record, let processor else { return }
            self?.applyingElapsed(record, processor)
        }
    }

    /// The applying deadline expired with no composited output: the processor
    /// is detached — so the track stops publishing substitutes — before idle
    /// is emitted. No effect was ever active, so no failure code fits.
    private func applyingElapsed(_ record: Attached, _ processor: CameraEffectProcessor) {
        lock.lock()
        guard attached === record, record.holds(processor), !record.activated else {
            lock.unlock()
            return
        }
        attached = nil
        let handle = record.handle
        record.handle = nil
        let bridge = self.bridge
        let idle = CameraEffectStatus.idle(generation: lastGeneration)
        status = idle
        let observer = self.observer
        lock.unlock()

        if let handle, let bridge { bridge.detach(handle) }
        processor.retire()
        emit(idle, to: observer)
    }

    private func frameProcessed(_ record: Attached, _ outcome: CameraFrameOutcome) {
        lock.lock()
        guard attached === record, record.holds(outcome.processor) else {
            lock.unlock()
            return
        }
        switch outcome.outcome {
        case .composited:
            record.substitution.end()
            guard !record.activated else {
                lock.unlock()
                return
            }
            record.activated = true
            let deadline = record.applyingDeadline
            record.applyingDeadline = nil
            let active = CameraEffectStatus.active(
                record.effect, generation: lastGeneration
            )
            status = active
            let observer = self.observer
            lock.unlock()

            deadline?.cancel()
            emit(active, to: observer)
        case .substituted:
            let sustained = record.substitution.extend(outcome.frame.timestampNs)
            guard record.activated, !record.failed, sustained else {
                lock.unlock()
                return
            }
            record.failed = true
            let failed = CameraEffectStatus.failed(
                record.effect,
                generation: lastGeneration,
                code: CameraEffectStatusCode.processingFailed
            )
            status = failed
            let observer = self.observer
            lock.unlock()

            emit(failed, to: observer)
        }
    }

    // MARK: - clear

    private func clear(generation: Int, completion: @escaping Completion) {
        lock.lock()
        lastGeneration = generation
        let record = attached
        let handle = record?.handle
        let applying = record?.applyingDeadline
        record?.applyingDeadline = nil
        attached = nil
        status = .idle(generation: generation)
        let bridge = self.bridge
        lock.unlock()

        applying?.cancel()
        if let handle, let bridge { bridge.detach(handle) }
        record?.currentProcessor().retire()
        finish(.done, completion)
    }

    // MARK: - Emission

    private func emit(
        _ status: CameraEffectStatus,
        to observer: ((CameraEffectStatus) -> Void)?
    ) {
        guard let observer else { return }
        delivery.deliver { observer(status) }
    }

    /// The unbroken run of substituted frames on one attachment, measured over
    /// the capture timestamps of the frames that produced them.
    private struct SubstitutionRun {
        private var startTimestampNs: Int64?

        /// Takes one substituted frame into the run, answering whether the run
        /// now covers `sustainedSubstitution`.
        mutating func extend(_ timestampNs: Int64) -> Bool {
            guard let start = startTimestampNs else {
                startTimestampNs = timestampNs
                return false
            }
            return timestampNs - start >= Int64(
                CameraEffectsService.sustainedSubstitution * 1_000_000_000
            )
        }

        mutating func end() {
            startTimestampNs = nil
        }
    }

    private struct Withheld {
        let record: Attached
        let deadline: CameraEffectsScheduledWork
        let completion: Completion
    }

    /// One track holding one processing callback. `effect`, `entered`,
    /// `activated`, `failed`, `substitution`, `handle` and `applyingDeadline`
    /// are guarded by the service's lock; the processor by this object's,
    /// which is the only lock the capture thread takes.
    private final class Attached {
        init(trackId: String, effect: CameraEffect, processor: CameraEffectProcessor) {
            self.trackId = trackId
            self.effect = effect
            self.processor = processor
        }

        let trackId: String
        var effect: CameraEffect
        var entered = false
        var activated = false
        var failed = false
        var substitution = SubstitutionRun()
        var handle: CameraTrackAttachment?
        var applyingDeadline: CameraEffectsScheduledWork?

        private let processorLock = NSLock()
        private var processor: CameraEffectProcessor

        func adopt(_ processor: CameraEffectProcessor) -> CameraEffectProcessor {
            processorLock.lock()
            let outgoing = self.processor
            self.processor = processor
            processorLock.unlock()
            return outgoing
        }

        func holds(_ processor: CameraEffectProcessor) -> Bool {
            processorLock.lock()
            defer { processorLock.unlock() }
            return self.processor === processor
        }

        func currentProcessor() -> CameraEffectProcessor {
            processorLock.lock()
            defer { processorLock.unlock() }
            return processor
        }

        func process(_ frame: CameraFrame) -> CameraFrameOutcome {
            processorLock.lock()
            let processor = self.processor
            processorLock.unlock()
            return processor.process(frame)
        }
    }
}
