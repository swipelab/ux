#if os(macOS)

import FlutterMacOS
import AppKit
import ux_macos_core

public class UrlPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/url", binaryMessenger: registrar.messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "launch":          handleLaunch(call, result: result)
        case "openAppSettings": handleOpenAppSettings(result: result)
        default:                result(FlutterMethodNotImplemented)
        }
    }

    /// macOS grants permissions per system pane rather than per app, so the
    /// recovery surface is System Settings' Privacy & Security section —
    /// where camera, microphone and screen-recording access is listed by app.
    private func handleOpenAppSettings(result: @escaping FlutterResult) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ) else {
            return result(false)
        }
        result(NSWorkspace.shared.open(url))
    }

    private func handleLaunch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let s = args["url"] as? String,
              let url = URL(string: LaunchUrl.encoded(s)) else {
            return result(false)
        }
        let ok = NSWorkspace.shared.open(url)
        result(ok)
    }
}

#endif
