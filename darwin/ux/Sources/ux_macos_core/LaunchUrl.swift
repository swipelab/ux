import Foundation

/// The string `UrlPlugin` hands `URL(string:)` for a link: each byte outside
/// RFC 3986's URL characters, a `#` after the first, and a `[` or `]` outside
/// the authority percent-encoded, so `URL(string:)` on iOS 16 and macOS 13,
/// which rejects them, parses a link written with non-ASCII text. A `%` that
/// two hex digits follow stays as written.
public enum LaunchUrl {
    public static func encoded(_ link: String) -> String {
        let bytes = Array(link.utf8)
        let authority = authority(bytes)
        var fragment = false
        var out = ""
        for (i, b) in bytes.enumerated() {
            let keep: Bool
            switch b {
            case UInt8(ascii: "%"):
                keep = i + 2 < bytes.count && isHex(bytes[i + 1]) && isHex(bytes[i + 2])
            case UInt8(ascii: "#"):
                keep = !fragment
                fragment = true
            case UInt8(ascii: "["), UInt8(ascii: "]"):
                keep = authority?.contains(i) == true
            default:
                keep = urlBytes.contains(b)
            }
            out += keep ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
        }
        return out
    }

    private static let urlBytes = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:/?@".utf8
    )

    private static func isHex(_ b: UInt8) -> Bool {
        Character(UnicodeScalar(b)).isHexDigit
    }

    private static func authority(_ bytes: [UInt8]) -> Range<Int>? {
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")),
              bytes[colon...].starts(with: "://".utf8) else { return nil }
        let start = colon + 3
        let end = bytes[start...].firstIndex {
            $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#")
        } ?? bytes.count
        return start..<end
    }
}
