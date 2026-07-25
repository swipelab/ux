#if os(iOS)

import Flutter
import Foundation
import UIKit

public class CrashPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/crash", binaryMessenger: registrar.messenger())
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
        CrashPlugin.installHandlerOnce()
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "drainPending":     handleDrain(result: result)
        case "ackCrash":         handleAck(call: call, result: result)
        case "triggerTestCrash": handleTriggerTestCrash(result: result)
        default:                 result(FlutterMethodNotImplemented)
        }
    }

    private func handleTriggerTestCrash(result: @escaping FlutterResult) {
        // Acknowledge first so the Dart side doesn't sit on a pending result
        // while the process winds down.
        result(nil)
        DispatchQueue.main.async {
            NSException(
                name: .invalidArgumentException,
                reason: "ux/crash triggerTestCrash",
                userInfo: nil
            ).raise()
        }
    }

    private func handleDrain(result: @escaping FlutterResult) {
        let dir = CrashPlugin.crashDirURL()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return result([])
        }
        // Oldest first so the receiver re-emits in original order.
        let sorted = names
            .filter { $0.hasSuffix(".json") }
            .sorted { lhs, rhs in
                let l = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(lhs).path)[.modificationDate]) as? Date ?? .distantPast
                let r = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(rhs).path)[.modificationDate]) as? Date ?? .distantPast
                return l < r
            }
        var out: [[String: Any]] = []
        for name in sorted {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? fm.removeItem(at: url)
                continue
            }
            var entry = json
            entry["id"] = (name as NSString).deletingPathExtension
            out.append(entry)
        }
        result(out)
    }

    private func handleAck(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let id = call.arguments as? String else {
            return result(FlutterError(code: "bad_args", message: "expected String id", details: nil))
        }
        let url = CrashPlugin.crashDirURL().appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        result(nil)
    }

    // MARK: - Handler install (process-global, idempotent)

    private static var installed = false
    fileprivate static var priorHandler: (@convention(c) (NSException) -> Void)?

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        // Ensure cache dir exists eagerly so the C handler can assume it.
        _ = try? FileManager.default.createDirectory(at: crashDirURL(), withIntermediateDirectories: true)
        priorHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(uxCrashHandler)
    }

    fileprivate static func crashDirURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("ux_crashes", isDirectory: true)
    }
}

// MARK: - Free C handler

// Process is going down; this function must finish on the crashing thread.
// No async dispatch, no Swift captures.
private func uxCrashHandler(_ exception: NSException) {
    let dir = CrashPlugin.crashDirURL()
    let fm = FileManager.default

    // Cap the directory at 50 files: drop oldest by mtime before writing.
    if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
        let jsons = names.filter { $0.hasSuffix(".json") }
        if jsons.count >= 50 {
            let sorted = jsons.sorted { lhs, rhs in
                let l = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(lhs).path)[.modificationDate]) as? Date ?? .distantPast
                let r = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(rhs).path)[.modificationDate]) as? Date ?? .distantPast
                return l < r
            }
            for old in sorted.prefix(jsons.count - 49) {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
            }
        }
    } else {
        _ = try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let payload: [String: Any] = [
        "platform": "ios",
        "time": iso.string(from: Date()),
        "name": exception.name.rawValue,
        "reason": exception.reason ?? "",
        "userInfo": (exception.userInfo ?? [:]).description,
        "callStackSymbols": exception.callStackSymbols,
        "callStackReturnAddresses": exception.callStackReturnAddresses.map { $0.intValue },
        "bundleId": Bundle.main.bundleIdentifier ?? "",
        "systemVersion": UIDevice.current.systemVersion,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        try? data.write(to: url, options: .atomic)
    }

    CrashPlugin.priorHandler?(exception)
}

#endif
