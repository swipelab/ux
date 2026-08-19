#if os(iOS)

import AVFoundation
import ux_macos_core

/// The input ports the session offers, and the preferred-input selection that
/// routes capture to one of them.
///
/// A port is identified by its `uid`. The session only enumerates inputs
/// under a recording category. The macOS counterpart is
/// `AudioInputs+macOS.swift`.
enum AudioInputs {
    /// Hardware inputs the session names. When the category does not
    /// expose inputs, the category becomes `.playAndRecord` under the
    /// current options without activating.
    static func list() -> [AudioInput] {
        let session = AVAudioSession.sharedInstance()
        if let ports = session.availableInputs {
            return ports.map { AudioInput(id: $0.uid, label: $0.portName) }
        }
        try? session.setCategory(.playAndRecord, options: session.categoryOptions)
        return (session.availableInputs ?? []).map {
            AudioInput(id: $0.uid, label: $0.portName)
        }
    }

    /// Routes capture to [input]. `engine` has no role: the session owns the
    /// route on iOS.
    static func select(_ input: AudioInput, engine: AVAudioEngine) -> Bool {
        AudioSession.upgradeForRecording()
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == input.id })
        else { return false }
        do {
            try session.setPreferredInput(port)
            return true
        } catch {
            return false
        }
    }
}

#endif
