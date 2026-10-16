#if os(macOS)

import AppKit

/// Hands `onChange` macOS's Reduce motion setting as `read` gives it, the
/// workspace's `accessibilityDisplayShouldReduceMotion`: once at init and
/// again on each `accessibilityDisplayOptionsDidChangeNotification` the
/// workspace's notification center posts, until the observer is released.
public final class ReduceMotionObserver {
    private let token: NSObjectProtocol

    public init(
        read: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        onChange: @escaping (Bool) -> Void
    ) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: nil,
        ) { _ in onChange(read()) }
        onChange(read())
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
}

#endif
