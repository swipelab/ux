import Foundation

/// macOS counterpart of `ios/Classes/Camera/AudioSession.swift`.
/// `AVAudioSession` is an iOS/tvOS/watchOS concept — macOS apps have
/// no such global category state. `AVCaptureSession` configures its
/// own audio routing on macOS, so this is a pure no-op.
enum AudioSession {
    static func upgradeForRecording() {}
}
