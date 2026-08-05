#if os(iOS)

import Flutter
import UIKit

/// `ux/window`, `keepAwake` only — iOS registers no `ux/window/events`
/// handler, so Dart's `XWindow.focused` stays at its default there.
///
/// The hold is `UIApplication.isIdleTimerDisabled`. The flag is cleared when
/// the app leaves the foreground and re-applied when it returns; it is
/// per-process, so it goes away with the app.
public class WindowPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    private var awake = false

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(
            name: "ux/window",
            binaryMessenger: registrar.messenger()
        )
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c

        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(onDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        nc.addObserver(
            self,
            selector: #selector(onDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil,
        )
    }

    deinit {
        let held = awake
        awake = false
        if held { DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false } }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "keepAwake":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                return result(FlutterError(
                    code: "bad_args", message: "enabled required", details: nil))
            }
            awake = enabled
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = enabled
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    @objc private func onDidBecomeActive() {
        UIApplication.shared.isIdleTimerDisabled = awake
    }

    @objc private func onDidEnterBackground() {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

#endif
