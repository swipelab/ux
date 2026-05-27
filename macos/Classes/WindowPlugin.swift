import AppKit
import FlutterMacOS

/// `ux/window/events`. Reports host-application focus state — emits
/// `{type: "focus", focused: Bool}` whenever the active NSApplication
/// flips. Seeded from `NSApp.isActive` when Dart subscribes so the
/// emitter starts in a deterministic value.
public class WindowPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    public func register(with registrar: FlutterPluginRegistrar) {
        let events = FlutterEventChannel(
            name: "ux/window/events",
            binaryMessenger: registrar.messenger,
        )
        events.setStreamHandler(self)
        eventChannel = events

        observeAppActivation()
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        emit(["type": "focus", "focused": NSApp.isActive])
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Observers

    private func observeAppActivation() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(onDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil,
        )
        nc.addObserver(
            self,
            selector: #selector(onDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil,
        )
    }

    @objc private func onDidBecomeActive() {
        emit(["type": "focus", "focused": true])
    }

    @objc private func onDidResignActive() {
        emit(["type": "focus", "focused": false])
    }

    private func emit(_ event: [String: Any]) {
        eventSink?(event)
    }
}
