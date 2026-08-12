#if os(iOS)

import Flutter
import ReplayKit

/// `ux/screen_sources` on iOS, where a capture is consent-driven: ReplayKit's
/// in-app recorder raises the consent alert itself and delivers frames to the
/// consumer's capture stack in-process, so nothing is enumerated and iOS asks
/// for no hold around the capture. What the bracket carries here is
/// ``RPScreenRecorder``'s arbitration — a recording it refuses while a mirrored
/// display or another recorder owns the screen — which `startShare` raises
/// before the consumer asks for a track that would never yield a frame. The
/// macOS counterpart, `ScreenSourcesPlugin.swift`, serves the picker snapshot.
public class ScreenSourcesPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "ux/screen_sources",
            binaryMessenger: registrar.uxMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        self.channel = channel
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "available":
            result(RPScreenRecorder.shared().isAvailable)
        case "startShare":
            guard RPScreenRecorder.shared().isAvailable else {
                return result(
                    FlutterError(
                        code: "service_start_failed",
                        message: "the screen recorder is unavailable",
                        details: nil
                    )
                )
            }
            result(nil)
        case "stopShare":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

#endif
