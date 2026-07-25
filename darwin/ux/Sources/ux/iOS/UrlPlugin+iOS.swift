#if os(iOS)

import Flutter
import UIKit

public class UrlPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/url", binaryMessenger: registrar.messenger())
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "launch": handleLaunch(call, result: result)
        default:       result(FlutterMethodNotImplemented)
        }
    }

    private func handleLaunch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let s = args["url"] as? String,
              let url = URL(string: s) else {
            return result(false)
        }
        DispatchQueue.main.async {
            let app = UIApplication.shared
            guard app.canOpenURL(url) else { return result(false) }
            app.open(url, options: [:]) { ok in
                result(ok)
            }
        }
    }
}

#endif
