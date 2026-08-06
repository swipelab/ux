#if os(macOS)

import Foundation
import FlutterMacOS
import ux_macos_core

/// `ux/camera_effects` + `ux/camera_effects/events`. Carries commands and
/// status between the channels and ``CameraEffectsService``, which owns the
/// state and has already marshalled every continuation onto the main queue.
public class CameraEffectsPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "ux/camera_effects",
            binaryMessenger: registrar.uxMessenger
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = methods

        let events = FlutterEventChannel(
            name: "ux/camera_effects/events",
            binaryMessenger: registrar.uxMessenger
        )
        events.setStreamHandler(self)
        eventChannel = events
    }

    deinit {
        CameraEffects.service.teardown()
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        events(CameraEffectsWire.encode(CameraEffects.service.currentStatus))
        CameraEffects.service.setStatusObserver { status in
            events(CameraEffectsWire.encode(status))
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        CameraEffects.service.setStatusObserver(nil)
        return nil
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch CameraEffectsWire.decode(
            method: call.method,
            arguments: call.arguments as? [String: Any]
        ) {
        case .unknownMethod:
            result(FlutterMethodNotImplemented)
        case .invalid(let failure):
            result(Self.error(failure))
        case .request(let request):
            CameraEffects.service.reply(to: request) { reply in
                Self.send(reply, to: result)
            }
        }
    }

    private static func send(_ reply: CameraEffectsReply, to result: FlutterResult) {
        switch reply {
        case .flag(let value):
            result(value)
        case .done:
            result(nil)
        case .failure(let failure):
            result(error(failure))
        }
    }

    private static func error(_ failure: CameraEffectsFailure) -> FlutterError {
        FlutterError(code: failure.code, message: failure.message, details: nil)
    }
}

#endif
