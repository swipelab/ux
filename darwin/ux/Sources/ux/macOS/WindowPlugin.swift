#if os(macOS)

import AppKit
import FlutterMacOS
import IOKit.pwr_mgt

/// `ux/window` + `ux/window/events`. The event channel reports
/// host-application focus state — `{type: "focus", focused: Bool}` whenever
/// the active NSApplication flips, seeded from `NSApp.isActive` when Dart
/// subscribes so the emitter starts in a deterministic value. The method
/// channel serves `keepAwake`, an `IOPMAssertion` against display sleep.
///
/// The assertion belongs to this process: powerd drops it when the app exits
/// or crashes, and the plugin drops it on `NSApplicationWillTerminate` and
/// when the engine releases the plugin.
public class WindowPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var assertion = IOPMAssertionID(0)
    private var awake = false

    public func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "ux/window",
            binaryMessenger: registrar.messenger,
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = methods

        let events = FlutterEventChannel(
            name: "ux/window/events",
            binaryMessenger: registrar.messenger,
        )
        events.setStreamHandler(self)
        eventChannel = events

        observeAppActivation()
    }

    deinit {
        releaseAwake()
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

    // MARK: - keepAwake

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "keepAwake":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                return result(FlutterError(
                    code: "bad_args", message: "enabled required", details: nil))
            }
            if enabled {
                guard holdAwake() else {
                    return result(FlutterError(
                        code: "keep_awake_failed",
                        message: "IOPMAssertionCreateWithName failed",
                        details: nil,
                    ))
                }
            } else {
                releaseAwake()
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func holdAwake() -> Bool {
        if awake { return true }
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ux keepAwake" as CFString,
            &id,
        )
        guard status == kIOReturnSuccess else { return false }
        assertion = id
        awake = true
        return true
    }

    private func releaseAwake() {
        guard awake else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(0)
        awake = false
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
        nc.addObserver(
            self,
            selector: #selector(onWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil,
        )
    }

    @objc private func onDidBecomeActive() {
        emit(["type": "focus", "focused": true])
    }

    @objc private func onDidResignActive() {
        emit(["type": "focus", "focused": false])
    }

    @objc private func onWillTerminate() {
        releaseAwake()
    }

    private func emit(_ event: [String: Any]) {
        eventSink?(event)
    }
}

#endif
