#if os(macOS)

import FlutterMacOS
import ux_macos_core

/// `ux/accessibility/events`: `{type: "reduceMotion", reduced: Bool}` from a
/// `ReduceMotionObserver` that lives while Dart listens.
public class AccessibilityPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private var eventChannel: FlutterEventChannel?
    private var observer: ReduceMotionObserver?

    public func register(with registrar: FlutterPluginRegistrar) {
        let events = FlutterEventChannel(
            name: "ux/accessibility/events",
            binaryMessenger: registrar.messenger,
        )
        events.setStreamHandler(self)
        eventChannel = events
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        observer = ReduceMotionObserver { reduced in
            events(["type": "reduceMotion", "reduced": reduced])
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        observer = nil
        return nil
    }
}

#endif
