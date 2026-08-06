#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ``ScreenCapturing`` over ScreenCaptureKit.
@available(macOS 14.0, *)
public final class ScreenCaptureKitCapture: ScreenCapturing {
    public init() {}

    private var content: SCShareableContent?

    public func shareableSources() async throws -> [ScreenSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false
        )
        self.content = content
        let names = await Self.displayNames()
        return content.displays.map { display in
            ScreenSource(
                kind: .display,
                id: String(display.displayID),
                title: names[display.displayID] ?? "Display \(display.displayID)",
                applicationName: nil,
                width: display.width,
                height: display.height
            )
        } + content.windows.map { window in
            ScreenSource(
                kind: .window,
                id: String(window.windowID),
                title: window.title ?? "",
                applicationName: window.owningApplication?.applicationName,
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }
    }

    public func captureImage(
        of source: ScreenSource,
        width: Int,
        height: Int
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: try filter(for: source),
            configuration: configuration
        )
    }

    private func filter(for source: ScreenSource) throws -> SCContentFilter {
        guard let content else {
            throw ScreenSourceError.enumerationFailed("no shareable content")
        }
        switch source.kind {
        case .display:
            guard
                let display = content.displays.first(where: {
                    String($0.displayID) == source.id
                })
            else { throw ScreenSourceError.thumbnailFailed("display \(source.id)") }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard
                let window = content.windows.first(where: {
                    String($0.windowID) == source.id
                })
            else { throw ScreenSourceError.thumbnailFailed("window \(source.id)") }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    @MainActor
    private static func displayNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ]
            if let id = (number as? NSNumber)?.uint32Value {
                names[id] = screen.localizedName
            }
        }
        return names
    }
}

#endif
