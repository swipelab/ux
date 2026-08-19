#if os(iOS)

import AVFoundation

/// iOS taps no playback: the only route to it is a ReplayKit screen
/// recording, which is a share, not an input. The macOS counterpart is
/// `AudioPlayback+macOS.swift`.
enum AudioPlayback {
    static var available: Bool { false }

    static func permitted() -> Bool { false }

    static func tap(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onStop: @escaping () -> Void
    ) -> AudioPlaybackCapturing? { nil }
}

#endif
