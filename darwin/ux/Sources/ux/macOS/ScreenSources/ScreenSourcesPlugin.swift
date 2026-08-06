#if os(macOS)

import Foundation
import FlutterMacOS
import ux_macos_core

/// `ux/screen_sources`. Carries the picker snapshot and the screen-recording
/// grant between the channel and ``ScreenSourcesService``.
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
        switch ScreenSourcesWire.decode(
            method: call.method,
            arguments: call.arguments as? [String: Any]
        ) {
        case .unknownMethod:
            result(FlutterMethodNotImplemented)
        case .invalid(let failure):
            result(Self.error(failure))
        case .request(let request):
            Task { @MainActor in
                Self.send(await Self.service().reply(to: request), to: result)
            }
        }
    }

    @MainActor
    private static func service() -> ScreenSourcesService {
        ScreenSourcesService(capture: capture(), permissions: SystemScreenPermissions())
    }

    @MainActor
    private static func capture() -> ScreenCapturing? {
        guard #available(macOS 14.0, *) else { return nil }
        return ScreenCaptureKitCapture()
    }

    private static func send(_ reply: ScreenSourcesReply, to result: FlutterResult) {
        switch reply {
        case .flag(let value):
            result(value)
        case .snapshot(let items):
            result(ScreenSourcesWire.encode(items).map(marshalled))
        case .failure(let failure):
            result(error(failure))
        }
    }

    /// The standard codec carries bytes as `FlutterStandardTypedData`.
    private static func marshalled(_ source: [String: Any]) -> [String: Any] {
        source.mapValues { (value: Any) -> Any in
            guard let data = value as? Data else { return value }
            return FlutterStandardTypedData(bytes: data)
        }
    }

    private static func error(_ failure: ScreenSourcesFailure) -> FlutterError {
        FlutterError(code: failure.code, message: failure.message, details: nil)
    }
}

#endif
