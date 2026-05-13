import AVFoundation

/// Idempotent helpers for upgrading the app's shared `AVAudioSession`
/// to the union of categories needed for capture without trampling
/// what other modules (audio player, video_player) had set. Pattern
/// mirrors `camera_avfoundation`'s `upgradeAudioSessionCategory` —
/// only ever WIDENS the category, never narrows.
///
/// We pair this with the session's
/// `automaticallyConfiguresApplicationAudioSession = false` +
/// `usesApplicationAudioSession = true` (set in [CameraSession.init])
/// so AVCaptureSession doesn't yank the category back.
enum AudioSession {
    /// Upgrade the shared category to include `.playAndRecord` (and
    /// the given options union'd with whatever's already set). No-op
    /// when the union equals the current state, so this is cheap to
    /// call on every recording start.
    static func upgradeForRecording() {
        upgrade(
            requestedCategory: .playAndRecord,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
        )
    }

    private static func upgrade(
        requestedCategory: AVAudioSession.Category,
        options: AVAudioSession.CategoryOptions
    ) {
        let playCategories: Set<AVAudioSession.Category> = [.playback, .playAndRecord]
        let recordCategories: Set<AVAudioSession.Category> = [.record, .playAndRecord]
        let currentCategory = AVAudioSession.sharedInstance().category
        let requiredCategories: Set<AVAudioSession.Category> = [
            requestedCategory, currentCategory,
        ]

        let requiresPlay = !requiredCategories.isDisjoint(with: playCategories)
        let requiresRecord = !requiredCategories.isDisjoint(with: recordCategories)

        var finalCategory = requestedCategory
        if requiresPlay && requiresRecord {
            finalCategory = .playAndRecord
        } else if requiresPlay {
            finalCategory = .playback
        } else if requiresRecord {
            finalCategory = .record
        }

        let finalOptions = AVAudioSession.sharedInstance().categoryOptions
            .union(options)

        if finalCategory == currentCategory
            && finalOptions == AVAudioSession.sharedInstance().categoryOptions
        {
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(
            finalCategory,
            options: finalOptions
        )
        // With AVCaptureSession.usesApplicationAudioSession = true and
        // automaticallyConfiguresApplicationAudioSession = false, the
        // app owns activation — without this, the mic input never
        // delivers sample buffers. Telegram does the same from
        // ManagedAudioSession.activate (setActive(true)).
        try? AVAudioSession.sharedInstance().setActive(
            true,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
