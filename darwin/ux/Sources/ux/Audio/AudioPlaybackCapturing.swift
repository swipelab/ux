import AVFoundation

/// A tap on what the device plays, delivering PCM buffers in whatever format
/// the platform hands out until [stop].
protocol AudioPlaybackCapturing: AnyObject {
    /// Opens the tap. The completion carries the failure that kept it shut,
    /// or `nil` once buffers flow.
    func start(completion: @escaping (String?) -> Void)

    /// Closes the tap. No buffer arrives after it returns.
    func stop()
}
