import Foundation

/// Work scheduled for later, cancellable before it runs.
public protocol CameraEffectsScheduledWork: AnyObject {
    func cancel()
}

/// Runs work after a delay. Injected so a test drives the attach deadline
/// without waiting for it.
public protocol CameraEffectsScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        _ body: @escaping () -> Void
    ) -> CameraEffectsScheduledWork
}

/// Hands work to Flutter's thread. Injected so a test sees which thread a
/// continuation lands on.
public protocol CameraEffectsDelivering: AnyObject {
    func deliver(_ body: @escaping () -> Void)
}

/// Monotonic seconds. Injected so a test advances time without sleeping.
public protocol CameraEffectsClock: AnyObject {
    var now: TimeInterval { get }
}

public final class UptimeClock: CameraEffectsClock {
    public init() {}

    public var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

public final class MainQueueScheduler: CameraEffectsScheduling {
    public init() {}

    public func schedule(
        after delay: TimeInterval,
        _ body: @escaping () -> Void
    ) -> CameraEffectsScheduledWork {
        let work = Work(body)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
        return work
    }

    private final class Work: CameraEffectsScheduledWork {
        init(_ body: @escaping () -> Void) {
            item = DispatchWorkItem(block: body)
        }

        let item: DispatchWorkItem

        func cancel() { item.cancel() }
    }
}

public final class MainQueueDelivery: CameraEffectsDelivering {
    public init() {}

    public func deliver(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}
