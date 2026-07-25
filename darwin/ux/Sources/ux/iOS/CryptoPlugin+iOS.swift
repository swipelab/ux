#if os(iOS)

import CommonCrypto
import Flutter
import Foundation

/// Native AES-256-CTR for chat-attachment upload encryption. Mirrors, byte for
/// byte, the app's pure-Dart `encryptChunk`: encrypts a slice as if a single
/// continuous CTR stream whose initial counter block is `iv` had already
/// processed `pos` plaintext bytes (CTR is symmetric, so the same call also
/// decrypts). Backed by CommonCrypto, which is hardware-accelerated on all
/// Apple targets. `kCCModeOptionCTR_BE` matches the Dart big-endian counter.
public class CryptoPlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?
    // Stateless per call, so a concurrent queue lets chunk encrypts use
    // multiple cores while staying off the platform main thread.
    private let queue = DispatchQueue(
        label: "ux.crypto", qos: .userInitiated, attributes: .concurrent)

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/crypto", binaryMessenger: registrar.messenger())
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "aesCtrRange": handleRange(call, result: result)
        case "aesCtrBytes": handleBytes(call, result: result)
        default:            result(FlutterMethodNotImplemented)
        }
    }

    private func handleRange(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let pos = (args["pos"] as? NSNumber)?.int64Value,
              let size = (args["size"] as? NSNumber)?.int64Value,
              let key = (args["key"] as? FlutterStandardTypedData)?.data,
              let iv = (args["iv"] as? FlutterStandardTypedData)?.data
        else {
            return result(FlutterError(code: "bad_args", message: "path/pos/size/key/iv required", details: nil))
        }
        guard key.count == 32, iv.count == 16 else {
            return result(FlutterError(code: "bad_args", message: "key must be 32 bytes, iv 16", details: nil))
        }
        queue.async {
            do {
                let plain = try Self.readRange(path: path, pos: pos, size: Int(size))
                let cipher = try Self.encrypt(key: [UInt8](key), iv: [UInt8](iv), pos: pos, plain: plain)
                DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: Data(cipher))) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "aes_failed", message: "\(error)", details: nil))
                }
            }
        }
    }

    private func handleBytes(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let pos = (args["pos"] as? NSNumber)?.int64Value,
              let key = (args["key"] as? FlutterStandardTypedData)?.data,
              let iv = (args["iv"] as? FlutterStandardTypedData)?.data,
              let data = (args["data"] as? FlutterStandardTypedData)?.data
        else {
            return result(FlutterError(code: "bad_args", message: "data/pos/key/iv required", details: nil))
        }
        guard key.count == 32, iv.count == 16 else {
            return result(FlutterError(code: "bad_args", message: "key must be 32 bytes, iv 16", details: nil))
        }
        queue.async {
            do {
                let cipher = try Self.encrypt(key: [UInt8](key), iv: [UInt8](iv), pos: pos, plain: [UInt8](data))
                DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: Data(cipher))) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "aes_failed", message: "\(error)", details: nil))
                }
            }
        }
    }

    private enum CryptoError: Error { case shortRead, cryptorFailed }

    /// Reads `size` bytes from `path` starting at `pos`.
    private static func readRange(path: String, pos: Int64, size: Int) throws -> [UInt8] {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw CryptoError.shortRead }
        defer { try? fh.close() }
        // Throwing seek(toOffset:) needs macOS 10.15.4 / iOS 13.4; the pod
        // targets 10.15, so fall back to the always-available legacy seek. The
        // else branch's availability context is < 10.15.4, so the non-throwing
        // seek(toFileOffset:) emits no deprecation warning.
        if #available(macOS 10.15.4, iOS 13.4, *) {
            try fh.seek(toOffset: UInt64(pos))
        } else {
            fh.seek(toFileOffset: UInt64(pos))
        }
        let data = fh.readData(ofLength: size)
        guard data.count == size else { throw CryptoError.shortRead }
        return [UInt8](data)
    }

    /// AES-256-CTR over `plain`, aligned to byte `pos` of a continuous stream
    /// from offset 0. The counter is seeded to block `pos>>4`; when `pos&15` is
    /// non-zero the sub-block offset is handled by prepending that many zero
    /// bytes in a single one-shot encrypt and dropping them (no cross-call
    /// cipher state). The block-aligned case (`pos&15 == 0`) skips that buffer
    /// and encrypts `plain` directly.
    private static func encrypt(key: [UInt8], iv: [UInt8], pos: Int64, plain: [UInt8]) throws -> [UInt8] {
        let counter = counterFor(iv, blocks: UInt64(pos >> 4))
        let byteOffset = Int(pos & 15)

        var cryptor: CCCryptorRef?
        let status = counter.withUnsafeBytes { ivPtr in
            key.withUnsafeBytes { keyPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, key.count,
                    nil, 0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), let cryptor = cryptor else {
            throw CryptoError.cryptorFailed
        }
        defer { CCCryptorRelease(cryptor) }

        let src: [UInt8]
        if byteOffset == 0 {
            src = plain
        } else {
            var buf = [UInt8](repeating: 0, count: byteOffset + plain.count)
            if !plain.isEmpty { buf.replaceSubrange(byteOffset..<buf.count, with: plain) }
            src = buf
        }

        var out = [UInt8](repeating: 0, count: src.count)
        var moved = 0
        let s2 = src.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, src.count,
                                outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        guard s2 == CCCryptorStatus(kCCSuccess), moved == src.count else {
            throw CryptoError.cryptorFailed
        }
        return byteOffset == 0 ? out : Array(out[byteOffset...])
    }

    /// `iv` (a 16-byte big-endian counter block) + `blocks`, carrying across all
    /// 16 bytes. Mirrors `incCounter` in the Dart reference exactly.
    private static func counterFor(_ iv: [UInt8], blocks: UInt64) -> [UInt8] {
        var c = iv
        var n = blocks
        var i = c.count - 1
        while i >= 0 && n > 0 {
            n += UInt64(c[i])
            c[i] = UInt8(n & 0xff)
            n >>= 8
            i -= 1
        }
        return c
    }
}

#endif
