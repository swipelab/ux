#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation

/// Resolves App Group container paths for `XAppGroup`. Identical on both
/// platforms — `FileManager` is the whole implementation, and it is
/// app-extension safe, so the plugin can register inside an extension host
/// as well as the app.
public class AppGroupPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
        let messenger = registrar.messenger()
        #else
        let messenger = registrar.messenger
        #endif
        let c = FlutterMethodChannel(name: "ux/app_group", binaryMessenger: messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "containerPath": handleContainerPath(call, result: result)
        default:              result(FlutterMethodNotImplemented)
        }
    }

    private func handleContainerPath(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let groupId = args["groupId"] as? String else {
            return result(FlutterError(code: "bad_args", message: "groupId is required", details: nil))
        }
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId)
        result(url?.path)
    }
}
