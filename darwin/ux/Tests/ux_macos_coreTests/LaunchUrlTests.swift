import Foundation
import XCTest

@testable import ux_macos_core

@available(iOS 17, macOS 14, *)
final class LaunchUrlTests: XCTestCase {
    /// `URL(string:)` as iOS 16 and macOS 13 parse, rejecting a character
    /// outside RFC 3986's URL characters.
    private func strictUrl(_ link: String) -> String? {
        URL(string: LaunchUrl.encoded(link), encodingInvalidCharacters: false)?.absoluteString
    }

    func testNonAsciiTextIsEscapedAsUtf8() {
        XCTAssertEqual(
            strictUrl("https://zh.wikipedia.org/wiki/北京_(城市)"),
            "https://zh.wikipedia.org/wiki/%E5%8C%97%E4%BA%AC_(%E5%9F%8E%E5%B8%82)"
        )
    }

    func testANonAsciiHostIsEscapedAsUtf8() {
        XCTAssertEqual(strictUrl("https://bücher.de/a"), "https://b%C3%BCcher.de/a")
    }

    func testAnEscapeStaysAndALonePercentIsEscaped() {
        XCTAssertEqual(strictUrl("https://example.com/aé%20b"), "https://example.com/a%C3%A9%20b")
        XCTAssertEqual(strictUrl("https://example.com/a%zz"), "https://example.com/a%25zz")
    }

    func testOnlyTheFirstHashStays() {
        XCTAssertEqual(strictUrl("http://example.org/b#c#d"), "http://example.org/b#c%23d")
    }

    func testBracketsStayOnlyInTheAuthority() {
        XCTAssertEqual(strictUrl("http://user@[::1]/a[b]"), "http://user@[::1]/a%5Bb%5D")
    }
}
