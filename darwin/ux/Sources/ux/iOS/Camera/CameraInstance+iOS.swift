#if os(iOS)

import Foundation
import UIKit

/// iOS-only app-lifecycle observer for [CameraInstance]. Hooks
/// `UIApplication.willResignActiveNotification` /
/// `.didBecomeActiveNotification` so backgrounding the app releases
/// the camera (and any in-flight recording is hard-cancelled —
/// matching every messaging app), and foregrounding restarts the
/// session if it had been running. macOS counterpart is a no-op
/// (`CameraInstance+macOS.swift`) — desktop background semantics are
/// less load-bearing for chat composer use.
///
/// `willResignActive` fires for phone calls and the app switcher;
/// `didBecomeActive` fires when the user returns. We hop work onto
/// the instance's `sessionQueue` so the AV teardown / start runs
/// serialised with other session mutations.
extension CameraInstance {
    func observeLifecycle() {
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.sessionQueueAsync { self.pauseForBackground() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.sessionQueueAsync { self.resumeForForeground() }
        })
        lifecycleCleanup = {
            for o in observers { center.removeObserver(o) }
        }
    }
}

#endif
