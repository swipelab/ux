import AVFoundation
import CoreMedia
import Foundation

/// Owns one `AVAssetWriter`. Mirrors telegram-ios's
/// [VideoRecorder.swift](file:///Users/agra/projects/telegram-ios/submodules/Camera/Sources/VideoRecorder.swift)
/// state machine closely — lazy per-type input creation,
/// gated `startWriting`, pending-audio-buffer queue:
///
/// 1. `start()` only creates the `AVAssetWriter` shell and sets
///    `recordingStartSampleTime` to wall-clock now. No inputs yet.
/// 2. First **video** sample → create `videoInput` from its
///    `CMFormatDescription` (`sourceFormatHint:`) + transform.
///    Pre-`startWriting` because audio input may still be pending.
/// 3. First **audio** sample (if `hasAudio`) → create `audioInput`
///    with sample-rate / channel-layout extracted from the audio
///    `CMFormatDescription` merged into `baseAudioSettings`
///    (`recommendedAudioSettingsForAssetWriter`).
/// 4. Next video sample arrives with both inputs added →
///    `assetWriter.startWriting()`. Sample is dropped (telegram's
///    behaviour — initial frame loss is acceptable, the writer needs
///    one cycle to settle).
/// 5. Subsequent video sample → `startSession(atSourceTime: pts)`,
///    `recordingStartSampleTime = pts`. Appends begin.
/// 6. Audio samples that arrive before `recordingStartSampleTime` is
///    set are queued in `pendingAudioSampleBuffers`. After each
///    successful video append, the queue is drained for samples whose
///    `endTime <= lastVideoSampleTime`.
/// 7. `stop()` sets `recordingStopSampleTime` to wall-clock now.
///    Sample callbacks set `hasAllVideoBuffers` / `hasAllAudioBuffers`
///    when their PTS crosses the stop time. `maybeFinish()` runs when
///    both flags are set, gates `finishWriting` on
///    `writer.status == .writing`. If audio never arrived, the audio
///    flag is set synchronously in `stop()` so the video side can
///    complete on its own.
///
/// Sample-count diagnostics emit via [onDiagnostic] at each major
/// checkpoint so the operator can verify "audio actually captured"
/// without instrumenting the call sites. The closure is wired to the
/// Dart-side `Log.tag('camera').i(...)` via the `ux/camera/events`
/// channel — visible in `~/banlu/tools/log_server/data/banlu.jsonl`.
final class VideoRecorder {
    /// Maps Flutter's `DeviceOrientation` to the rotation transform
    /// embedded as `AVAssetWriterInput.transform`. Source buffers
    /// are portrait-shape (see [CameraInstance.applyVideoOrientationOnPreview]),
    /// so the table assumes portrait source — see
    /// [CameraOrientationTests] for the four cases.
    public static func transform(
        for orientation: DeviceOrientationFlutter
    ) -> CGAffineTransform {
        switch orientation {
        case .portraitUp:        return .identity
        case .portraitDown:      return CGAffineTransform(rotationAngle: .pi)
        case .landscapeLeft:     return CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeRight:    return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }

    // MARK: - immutable config

    private let url: URL
    private let videoTransform: CGAffineTransform
    private let hasAudio: Bool
    private let baseVideoSettings: [String: Any]?
    private let baseAudioSettings: [String: Any]
    private let recorderQueue: DispatchQueue

    // MARK: - mutable state (always touched on recorderQueue)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    /// Wall-clock "start" time set by [start], then overwritten to the
    /// first video sample's PTS once the session is started. Used to
    /// gate samples whose PTS is older than start.
    private var recordingStartSampleTime: CMTime = .invalid

    /// Set by [stop]. Samples whose PTS crosses this set the matching
    /// `hasAllXBuffers` flag and trigger [maybeFinish].
    private var recordingStopSampleTime: CMTime = .invalid

    /// PTS of the last video sample successfully appended. Used to
    /// gate audio drains (audio samples whose `endTime` exceeds this
    /// stay queued until video catches up).
    private var lastVideoSampleTime: CMTime = .invalid

    private var startedSession = false
    private var stopped = false
    private var hasAllVideoBuffers = false
    private var hasAllAudioBuffers = false
    private var failed = false

    /// Audio samples arriving before video has caught up. Drained
    /// after each successful video append.
    private var pendingAudioSampleBuffers: [CMSampleBuffer] = []

    private var completion: ((Result<URL, NSError>) -> Void)?

    // MARK: - diagnostics (emit via [onDiagnostic] → ux.Log)

    private func diag(_ message: String) {
        onDiagnostic?(message)
    }

    private var videoReceived: Int = 0
    private var videoAppended: Int = 0
    private var audioReceived: Int = 0
    private var audioAppended: Int = 0
    private var audioQueued: Int = 0

    /// Set by [CameraInstance] to ship diagnostic messages over the
    /// `ux/camera/events` channel as `{event: "diagnostic"}`. The
    /// Dart-side controller turns those into `Log.tag('camera').i(...)`
    /// — so they land in the log_server pipeline and can be tailed
    /// from `~/banlu/tools/log_server/data/banlu.jsonl`.
    var onDiagnostic: ((String) -> Void)?

    // MARK: - init / start

    init(
        url: URL,
        orientation: DeviceOrientationFlutter,
        hasAudio: Bool,
        baseVideoSettings: [String: Any]?,
        baseAudioSettings: [String: Any],
        recorderQueue: DispatchQueue
    ) {
        self.url = url
        self.videoTransform = VideoRecorder.transform(for: orientation)
        self.hasAudio = hasAudio
        self.baseVideoSettings = baseVideoSettings
        self.baseAudioSettings = baseAudioSettings
        self.recorderQueue = recorderQueue
    }

    /// Open the file. Inputs are created lazily on the first sample
    /// of each type — see class doc. Throws on `AVAssetWriter`
    /// allocation failure (typically a path / file-system issue).
    func start() throws {
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        self.writer = writer
        // Sentinel until the first video sample's PTS overwrites it —
        // see [handleVideo] when it calls `writer.startSession`.
        recordingStartSampleTime = CMTime(
            seconds: CACurrentMediaTime(),
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )
        diag("start: file=\(url.lastPathComponent) hasAudio=\(hasAudio)")
    }

    /// Hard cancel — drop pending audio, `cancelWriting` if the writer
    /// is writing, delete the partial file. Mirrors telegram-ios's
    /// [`VideoRecorder.cancelRecording`](file:///Users/agra/projects/telegram-ios/submodules/Camera/Sources/VideoRecorder.swift#L329).
    /// Used by [CameraInstance.dispose] when a recording is in flight
    /// at teardown — there's no caller to deliver the file to, so no
    /// reason to wait for `finishWriting` to flush.
    func cancel(completion: (() -> Void)? = nil) {
        recorderQueue.async {
            if self.stopped || self.failed {
                completion?()
                return
            }
            self.stopped = true
            self.pendingAudioSampleBuffers = []
            if let writer = self.writer, writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: self.url)
            self.diag("cancel: vRecv=\(self.videoReceived) aRecv=\(self.audioReceived)")
            // Resolve any pending stop() completion so the caller's
            // Future doesn't dangle.
            if let cb = self.completion {
                self.completion = nil
                cb(.failure(NSError(
                    domain: "ux.camera", code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "Recording cancelled"]
                )))
            }
            completion?()
        }
    }

    /// Stop. Sets `recordingStopSampleTime` so the next video / audio
    /// sample crossing it flips the matching `hasAllXBuffers` flag,
    /// which triggers `maybeFinish` → `finishWriting`. Completion
    /// fires once when the writer finishes.
    ///
    /// Idempotent: a second call while a stop is already in flight is
    /// silently dropped.
    func stop(completion: @escaping (Result<URL, NSError>) -> Void) {
        recorderQueue.async {
            if self.completion != nil { return }
            self.completion = completion

            let stopTime = CMTime(
                seconds: CACurrentMediaTime(),
                preferredTimescale: CMTimeScale(NSEC_PER_SEC)
            )
            self.recordingStopSampleTime = stopTime

            self.diag("stop: vRecv=\(self.videoReceived) vApp=\(self.videoAppended)"
                + " aRecv=\(self.audioReceived) aApp=\(self.audioAppended)"
                + " aQueued=\(self.pendingAudioSampleBuffers.count)")

            // Nothing ever arrived — no sample callback will ever
            // trigger `maybeFinish`. Cancel the writer instead.
            if !self.startedSession {
                self.writer?.cancelWriting()
                self.failed = true
                self.deliver(.failure(NSError(
                    domain: "ux.camera", code: -11,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Recording stopped before any samples were written"
                    ]
                )))
                return
            }

            // No audio path (mic permission denied, etc.) — the audio
            // side is "drained" by definition. `maybeFinish` then only
            // waits for the next video sample whose PTS crosses
            // `stopTime` (~one frame later, ~33ms at 30fps).
            if self.audioInput == nil || self.audioReceived == 0 {
                self.hasAllAudioBuffers = true
            }
        }
    }

    // MARK: - sample append (from videoBufferQueue / audioBufferQueue)

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        recorderQueue.async { self.handleVideo(sampleBuffer) }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        recorderQueue.async { self.handleAudio(sampleBuffer) }
    }

    // MARK: - recorderQueue handlers

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !stopped, !failed else { return }
        guard let writer = writer else { return }
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video
        else { return }

        videoReceived += 1
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 1. Lazy create the video input on first video sample, with
        //    the buffer's format description as `sourceFormatHint`.
        if videoInput == nil {
            let videoSettings = baseVideoSettings ?? [:]
            if writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
                let input = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: videoSettings,
                    sourceFormatHint: formatDescription
                )
                input.expectsMediaDataInRealTime = true
                input.transform = videoTransform
                if writer.canAdd(input) {
                    writer.add(input)
                    videoInput = input
                    diag("video input added")
                } else {
                    fail(NSError(domain: "ux.camera", code: -30,
                                 userInfo: [NSLocalizedDescriptionKey: "canAdd videoInput failed"]))
                    return
                }
            } else {
                fail(NSError(domain: "ux.camera", code: -31,
                             userInfo: [NSLocalizedDescriptionKey: "canApply videoSettings failed"]))
                return
            }
        }

        // 2. Writer state machine
        if writer.status == .unknown {
            // Drop samples that arrived BEFORE the wall-clock start
            // (rare, but happens if the session was already running
            // before start() was called).
            if presentationTime < recordingStartSampleTime {
                return
            }
            // Only start the writer when ALL needed inputs are ready.
            if videoInput != nil && (audioInput != nil || !hasAudio) {
                if !writer.startWriting() {
                    fail(writer.error)
                    return
                }
                diag("startWriting")
            }
            // Drop this sample regardless — the writer needs a cycle
            // to settle. Next sample will hit the `.writing` branch.
            return
        } else if writer.status == .writing && !startedSession {
            writer.startSession(atSourceTime: presentationTime)
            recordingStartSampleTime = presentationTime
            lastVideoSampleTime = presentationTime
            startedSession = true
            diag(String(format: "startSession at %.3fs", presentationTime.seconds))
        }

        // Drop pre-start samples (post-startSession).
        if recordingStartSampleTime == .invalid
            || presentationTime < recordingStartSampleTime {
            return
        }

        if writer.status == .writing && startedSession {
            // 3. Stop-time gating — set hasAllVideoBuffers when we
            //    see a sample past stop time, trigger finish.
            if recordingStopSampleTime.isValid
                && presentationTime > recordingStopSampleTime {
                hasAllVideoBuffers = true
                maybeFinish()
                return
            }

            guard let input = videoInput else { return }
            // Busy-wait briefly if the input isn't ready. Matches
            // telegram-ios's pattern at VideoRecorder.swift:202-206.
            // Real-time capture; we can't backpressure the camera.
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }

            if input.append(sampleBuffer) {
                lastVideoSampleTime = presentationTime
                videoAppended += 1
            }

            // 4. Drain any pending audio whose endTime now fits
            //    under lastVideoSampleTime.
            if !tryAppendingPendingAudioBuffers() {
                fail(writer.error)
            }
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !stopped, !failed, hasAudio else { return }
        guard let writer = writer else { return }
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio
        else { return }

        audioReceived += 1

        // 1. Lazy create audio input on first audio sample, with
        //    sample-rate / channel-layout extracted from the
        //    sample's CMAudioFormatDescription.
        if audioInput == nil {
            var audioSettings = baseAudioSettings

            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                audioSettings[AVSampleRateKey] = asbd.pointee.mSampleRate
                audioSettings[AVNumberOfChannelsKey] = asbd.pointee.mChannelsPerFrame
            }

            var channelLayoutSize: Int = 0
            let channelLayoutPtr = CMAudioFormatDescriptionGetChannelLayout(
                formatDescription, sizeOut: &channelLayoutSize
            )
            let channelLayoutData: Data
            if let ptr = channelLayoutPtr, channelLayoutSize > 0 {
                channelLayoutData = Data(bytes: ptr, count: channelLayoutSize)
            } else {
                channelLayoutData = Data()
            }
            audioSettings[AVChannelLayoutKey] = channelLayoutData

            if writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings,
                    sourceFormatHint: formatDescription
                )
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                    diag("audio input added"
                         + " sr=\(audioSettings[AVSampleRateKey] ?? "?")"
                         + " ch=\(audioSettings[AVNumberOfChannelsKey] ?? "?")")
                } else {
                    diag("canAdd audioInput failed")
                    return
                }
            } else {
                diag("canApply audioSettings failed")
                return
            }
        }

        // 2. Need the video stream to have given us a session start
        //    time before any audio can be appended.
        if recordingStartSampleTime == .invalid { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if presentationTime < recordingStartSampleTime { return }

        // 3. Stop-time gating.
        if recordingStopSampleTime.isValid
            && presentationTime > recordingStopSampleTime {
            hasAllAudioBuffers = true
            maybeFinish()
            return
        }

        // 4. Append (or queue) — drain pending first, then this
        //    sample. tryAppendingAudioSampleBuffer chooses queue vs
        //    immediate-append based on its endTime vs lastVideoSampleTime.
        if !tryAppendingPendingAudioBuffers()
            || !tryAppendingAudioSampleBuffer(sampleBuffer) {
            fail(writer.error)
        }
    }

    // MARK: - audio buffer queue

    /// Append [sampleBuffer] immediately if its `endTime` doesn't
    /// run past the latest video sample; otherwise enqueue.
    private func tryAppendingAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if sampleBuffer.endTime > lastVideoSampleTime {
            pendingAudioSampleBuffers.append(sampleBuffer)
            audioQueued += 1
            return true
        }
        return internalAppendAudioSampleBuffer(sampleBuffer)
    }

    /// Drain queued audio samples that have caught up to the latest
    /// video sample. Called after every video append.
    private func tryAppendingPendingAudioBuffers() -> Bool {
        guard !pendingAudioSampleBuffers.isEmpty else { return true }

        var stillPending: [CMSampleBuffer] = []
        stillPending.reserveCapacity(pendingAudioSampleBuffers.count)
        var ok = true
        for sample in pendingAudioSampleBuffers {
            if !ok {
                stillPending.append(sample)
                continue
            }
            if sample.endTime <= lastVideoSampleTime {
                if !internalAppendAudioSampleBuffer(sample) {
                    ok = false
                }
            } else {
                stillPending.append(sample)
            }
        }
        pendingAudioSampleBuffers = stillPending
        return ok
    }

    private func internalAppendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard startedSession, let input = audioInput else { return true }
        while !input.isReadyForMoreMediaData {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if input.append(sampleBuffer) {
            audioAppended += 1
            return true
        }
        if writer?.error != nil {
            return false
        }
        // Append returned false but no writer error — treat as
        // recoverable. Telegram does the same.
        return true
    }

    // MARK: - finish

    private func maybeFinish() {
        guard hasAllVideoBuffers,
              (!hasAudio || hasAllAudioBuffers),
              !stopped, !failed else { return }
        stopped = true
        finish()
    }

    private func finish() {
        // Drain any audio buffer still pending up to the stop time.
        _ = tryAppendingPendingAudioBuffers()

        guard let writer = writer else {
            deliver(.failure(NSError(
                domain: "ux.camera", code: -40,
                userInfo: [NSLocalizedDescriptionKey: "writer missing on finish"]
            )))
            return
        }

        // Only `finishWriting` when the writer reached `.writing`.
        guard writer.status == .writing else {
            diag("finish skipped — writer.status=\(writer.status.rawValue)")
            failOnError(writer.error)
            return
        }

        let url = self.url
        diag("finishWriting:"
            + " vRecv=\(videoReceived) vApp=\(videoAppended)"
            + " aRecv=\(audioReceived) aApp=\(audioAppended)"
            + " aQueuedDrop=\(pendingAudioSampleBuffers.count)")

        writer.finishWriting { [weak self] in
            self?.recorderQueue.async {
                guard let self = self else { return }
                if writer.status == .completed {
                    self.deliver(.success(url))
                } else {
                    self.failOnError(writer.error)
                }
            }
        }
    }

    private func fail(_ error: Error?) {
        if failed { return }
        failed = true
        failOnError(error)
    }

    private func failOnError(_ error: Error?) {
        try? FileManager.default.removeItem(at: url)
        let ns = (error as NSError?) ?? NSError(
            domain: "ux.camera", code: -41,
            userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed"]
        )
        deliver(.failure(ns))
    }

    private func deliver(_ outcome: Result<URL, NSError>) {
        let cb = completion
        completion = nil
        cb?(outcome)
    }
}

// MARK: - CMSampleBuffer ergonomics

private extension CMSampleBuffer {
    /// `presentationTime + duration` — last instant covered by this
    /// buffer. Used to pace audio against video.
    var endTime: CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(self)
        let dur = CMSampleBufferGetDuration(self)
        if dur.flags.contains(.valid) {
            return pts + dur
        }
        return pts
    }
}
