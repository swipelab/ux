#if os(macOS)

import AVFoundation
import ScreenCaptureKit
import ux_macos_core

/// The device-playback tap on macOS: an audio-only ScreenCaptureKit stream,
/// which the window server grants under screen recording. The iOS counterpart
/// is `AudioPlayback+iOS.swift`, where nothing taps playback.
enum AudioPlayback {
    /// Whether this host taps its own output.
    static var available: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Whether the tap is granted, asking for the grant when it has not been
    /// answered yet.
    static func permitted() -> Bool {
        let permissions = SystemScreenPermissions()
        return permissions.isGranted || permissions.request()
    }

    static func tap(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onStop: @escaping () -> Void
    ) -> AudioPlaybackCapturing? {
        guard #available(macOS 13.0, *) else { return nil }
        return ScreenCaptureAudioTap(onBuffer: onBuffer, onStop: onStop)
    }
}

@available(macOS 13.0, *)
private final class ScreenCaptureAudioTap: NSObject, AudioPlaybackCapturing,
    SCStreamOutput, SCStreamDelegate
{
    init(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onStop: @escaping () -> Void
    ) {
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let onStop: () -> Void
    private let samples = DispatchQueue(label: "io.swipelab.ux.audio-playback")
    private var stream: SCStream?

    func start(completion: @escaping (String?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else { return completion("tap released") }
            guard let display = content?.displays.first else {
                return completion(error?.localizedDescription ?? "no display")
            }
            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingWindows: []),
                configuration: Self.configuration(),
                delegate: self
            )
            do {
                try stream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: self.samples
                )
            } catch {
                return completion(error.localizedDescription)
            }
            stream.startCapture { error in
                if let error { return completion(error.localizedDescription) }
                self.stream = stream
                completion(nil)
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let description = sampleBuffer.formatDescription else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                bufferListNoCopy: list.unsafePointer
            ) else { return }
            onBuffer(buffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop()
    }

    private static func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // The host's own output loops: a dub it plays would re-enter as
        // captured audio.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // A stream always renders video; the smallest frame at the slowest
        // cadence is the cheapest one to throw away.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return configuration
    }
}

#endif
