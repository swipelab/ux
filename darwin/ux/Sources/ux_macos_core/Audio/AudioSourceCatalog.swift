import Foundation

/// What an audio source taps, spelled as `ux/audio_capture` carries it.
public enum AudioSourceKind: String, Sendable {
    case microphone
    case playback
}

/// One input the channel offers Dart.
public struct AudioSource: Equatable, Sendable {
    public init(id: String, label: String, kind: AudioSourceKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    public let id: String
    public let label: String
    public let kind: AudioSourceKind

    public var wire: [String: String] {
        ["id": id, "label": label, "kind": kind.rawValue]
    }
}

/// A hardware input, as the platform enumerates it.
public struct AudioInput: Equatable, Sendable {
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    public let id: String
    public let label: String
}

/// What a `start` call opens.
public enum AudioSourceSelection: Equatable, Sendable {
    case defaultInput
    case microphone(AudioInput)
    case playback
    case unknown
}

/// An Apple platform family, which decides whether device playback can be
/// tapped at all.
public enum AudioHost: Sendable {
    case iOS
    case macOS

    /// The family this build runs on.
    public static var current: AudioHost {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }

    /// Whether the family taps what the device plays.
    public var tapsPlayback: Bool { self == .macOS }
}

/// The sources one host offers, and what a `sourceId` from Dart names.
public struct AudioSourceCatalog: Sendable {
    /// The playback source's id, spelled the same on every platform.
    public static let playbackId = "playback"

    /// Its label, for a host that reports no name of its own for the output.
    public static let playbackLabel = "Device playback"

    /// `playbackReady` is this host's runtime answer — the OS version behind
    /// the tap. A family that taps no playback offers none however it answers.
    public init(host: AudioHost, playbackReady: Bool) {
        self.host = host
        self.playbackReady = playbackReady
    }

    private let host: AudioHost
    private let playbackReady: Bool

    private var offersPlayback: Bool { host.tapsPlayback && playbackReady }

    public func sources(inputs: [AudioInput]) -> [AudioSource] {
        var sources = inputs.map {
            AudioSource(id: $0.id, label: $0.label, kind: .microphone)
        }
        if offersPlayback {
            sources.append(
                AudioSource(
                    id: Self.playbackId,
                    label: Self.playbackLabel,
                    kind: .playback
                )
            )
        }
        return sources
    }

    /// [inputs] is read only where the id could name one, so the default
    /// selection costs no enumeration — which on iOS widens the session
    /// category.
    public func selection(
        for sourceId: String?,
        inputs: () -> [AudioInput]
    ) -> AudioSourceSelection {
        guard let sourceId else { return .defaultInput }
        if sourceId == Self.playbackId {
            return offersPlayback ? .playback : .unknown
        }
        guard let input = inputs().first(where: { $0.id == sourceId }) else {
            return .unknown
        }
        return .microphone(input)
    }
}
