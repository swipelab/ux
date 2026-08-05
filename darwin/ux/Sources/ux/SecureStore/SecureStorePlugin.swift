import Foundation
import Security

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// `ux/secure_store`. One `kSecClassGenericPassword` Keychain item per key:
/// service is the host bundle identifier, account is the key, and
/// `kSecAttrSynchronizable` is false so no value reaches iCloud or another
/// device.
///
/// iOS items are `kSecAttrAccessibleAfterFirstUnlock`, so a token survives a
/// reboot and is readable by background work once the user has unlocked once.
/// macOS uses the file-based keychain — the data-protection keychain there
/// answers `errSecMissingEntitlement` unless the host carries a
/// keychain-access-group entitlement, which a locally signed app does not.
///
/// Failures carry an `OSStatus`; keys and values never leave through an error
/// message or a log line.
public class SecureStorePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    private let service = Bundle.main.bundleIdentifier ?? "io.swipelab.ux"

    /// Keychain calls block on the securityd round-trip, so they stay off the
    /// platform thread; the Dart side serializes commands, so one queue is
    /// enough to keep a read after a write ordered.
    private let queue = DispatchQueue(label: "ux.secure_store", qos: .userInitiated)

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(
            name: "ux/secure_store",
            binaryMessenger: registrar.uxMessenger
        )
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String, !key.isEmpty else {
            return result(FlutterError(code: "bad_args", message: "key required", details: nil))
        }
        switch call.method {
        case "read":
            run(result) { try self.read(key) }
        case "write":
            guard let value = args["value"] as? String else {
                return result(FlutterError(code: "bad_args", message: "value required", details: nil))
            }
            run(result) { try self.write(key, value); return nil }
        case "delete":
            run(result) { try self.delete(key); return nil }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func run(_ result: @escaping FlutterResult, _ work: @escaping () throws -> String?) {
        queue.async {
            do {
                let value = try work()
                DispatchQueue.main.async { result(value) }
            } catch let error as KeychainError {
                DispatchQueue.main.async {
                    result(FlutterError(code: "store_failed", message: error.description, details: nil))
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "store_failed", message: "\(error)", details: nil))
                }
            }
        }
    }

    // MARK: - Keychain

    private func read(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    private func write(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }

        var insert = query
        insert[kSecValueData as String] = data
        #if os(iOS)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    private func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

private struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String { "OSStatus \(status)" }
}
