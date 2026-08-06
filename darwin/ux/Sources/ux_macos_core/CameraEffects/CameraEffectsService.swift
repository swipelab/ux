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

    /// The window an attach has to see its first frame.
    static let attachDeadline: TimeInterval = 0.75

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

    public func install(_ bridge: CameraTrackBridging) {
        lock.lock()
        self.bridge = bridge
        lock.unlock()
    }

    /// Drops the bridge. A live attachment is abandoned without a bridge call
    /// and reported once as a failure; a withheld reply resolves immediately
    /// rather than waiting out its deadline.
    public func uninstall() {
        lock.lock()
        bridge = nil
        let record = attached
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
        let handle = attached?.handle
        let pending = withheld
        let bridge = self.bridge
        attached = nil
        withheld = nil
        queued.removeAll()
        serving = false
        lock.unlock()

        pending?.deadline.cancel()
        if let handle, let bridge { bridge.detach(handle) }
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
            current.adopt(processor)
            lock.unlock()
            emit(applying, to: observer)
            return finish(.done, completion)
        }

        let previous = attached
        let record = Attached(trackId: trackId, effect: effect, processor: processor)
        attached = record
        let deadline = scheduler.schedule(after: Self.attachDeadline) {
            [weak self, weak record] in
            guard let record else { return }
            self?.deadlineElapsed(record)
        }
        withheld = Withheld(record: record, deadline: deadline, completion: completion)
        lock.unlock()

        emit(applying, to: observer)
        if let handle = previous?.handle { bridge.detach(handle) }

        do {
            let handle = try bridge.attach(
                trackId: trackId,
                processing: { [weak self] frame in
                    self?.callbackEntered(record)
                    return record.process(frame)
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
        emit(idle, to: observer)
        finish(.failure(.trackNotProcessable), pending.completion)
    }

    private func callbackEntered(_ record: Attached) {
        lock.lock()
        guard attached === record, !record.activated else {
            lock.unlock()
            return
        }
        record.activated = true
        var pending = withheld
        if pending?.record === record {
            withheld = nil
        } else {
            pending = nil
        }
        let active = CameraEffectStatus.active(record.effect, generation: lastGeneration)
        status = active
        let observer = self.observer
        lock.unlock()

        pending?.deadline.cancel()
        emit(active, to: observer)
        if let pending { finish(.done, pending.completion) }
    }

    // MARK: - clear

    private func clear(generation: Int, completion: @escaping Completion) {
        lock.lock()
        lastGeneration = generation
        let handle = attached?.handle
        attached = nil
        status = .idle(generation: generation)
        let bridge = self.bridge
        lock.unlock()

        if let handle, let bridge { bridge.detach(handle) }
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

    private struct Withheld {
        let record: Attached
        let deadline: CameraEffectsScheduledWork
        let completion: Completion
    }

    /// One track holding one processing callback. `effect`, `activated` and
    /// `handle` are guarded by the service's lock; the processor by this
    /// object's, which is the only lock the capture thread takes.
    private final class Attached {
        init(trackId: String, effect: CameraEffect, processor: CameraEffectProcessor) {
            self.trackId = trackId
            self.effect = effect
            self.processor = processor
        }

        let trackId: String
        var effect: CameraEffect
        var activated = false
        var handle: CameraTrackAttachment?

        private let processorLock = NSLock()
        private var processor: CameraEffectProcessor

        func adopt(_ processor: CameraEffectProcessor) {
            processorLock.lock()
            self.processor = processor
            processorLock.unlock()
        }

        func process(_ frame: CameraFrame) -> CameraFrame {
            processorLock.lock()
            let processor = self.processor
            processorLock.unlock()
            return processor.process(frame)
        }
    }
}
