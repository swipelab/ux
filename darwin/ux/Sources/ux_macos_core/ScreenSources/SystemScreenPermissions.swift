#if os(macOS)

import CoreGraphics

/// ``ScreenPermissions`` over the window server's screen-recording grant.
public struct SystemScreenPermissions: ScreenPermissions {
    public init() {}

    public var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    public func request() -> Bool { CGRequestScreenCaptureAccess() }
}

#endif
