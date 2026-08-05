import AVFoundation

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// `ux/audio_capture` + `ux/audio_capture/events`. Taps the microphone
/// through `AVAudioEngine` and pushes fixed-size mono 16 kHz Int16 frames to
/// Dart, resampling from whatever format the input node runs at.
///
/// A tap reads the input node without owning the capture graph, so another
/// module holding the microphone (a call, a recorder) keeps it.
///
/// Interruption reporting differs per platform: iOS has
/// `AVAudioSession` interruption and route-change notifications, macOS has
/// neither — there the engine's configuration-change notification (default
/// input device swapped or removed) is the only signal, so a macOS capture
/// survives everything short of the device itself going away.
public class AudioCapturePlugin: NSObject, NativePlugin, FlutterStreamHandler {
    /// Samples per emitted frame — 20 ms at 16 kHz.
    private static let frameSamples = 320

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var converter: AVAudioConverter?
    private var pending: [Int16] = []
    private var running = false

    public func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "ux/audio_capture",
            binaryMessenger: registrar.uxMessenger
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = methods

        let events = FlutterEventChannel(
            name: "ux/audio_capture/events",
            binaryMessenger: registrar.uxMessenger
        )
        events.setStreamHandler(self)
        eventChannel = events

        observe()
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start": start(result: result)
        case "stop":
            stopEngine()
            emitState("idle", reason: nil)
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func start(result: @escaping FlutterResult) {
        guard !running else { return result(nil) }
        requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                return result(FlutterError(
                    code: "permission_denied",
                    message: "microphone",
                    details: nil
                ))
            }
            // iOS-only category widening; the macOS build of `AudioSession`
            // is a no-op.
            AudioSession.upgradeForRecording()

            let input = self.engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            // A host with no usable input reports a zero-rate format —
            // installing a tap against it traps.
            guard inputFormat.sampleRate > 0 else {
                return result(FlutterError(
                    code: "no_input_device",
                    message: "no microphone input",
                    details: nil
                ))
            }
            guard let converter = AVAudioConverter(
                from: inputFormat,
                to: self.outputFormat
            ) else {
                return result(FlutterError(
                    code: "start_failed",
                    message: "cannot convert \(inputFormat) to 16 kHz Int16",
                    details: nil
                ))
            }
            // AVAudioConverter downmixes mono and stereo on its own but
            // converts a wider layout — a built-in mic array is three
            // channels — to silence. Map the primary element instead.
            if inputFormat.channelCount > 2 {
                converter.channelMap = [0]
            }
            self.converter = converter
            self.pending.removeAll(keepingCapacity: true)

            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) {
                [weak self] buffer, _ in
                self?.consume(buffer)
            }
            self.engine.prepare()
            do {
                try self.engine.start()
            } catch {
                input.removeTap(onBus: 0)
                self.converter = nil
                return result(FlutterError(
                    code: "start_failed",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
            self.running = true
            self.emitState("running", reason: nil)
            result(nil)
        }
    }

    private func stopEngine() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        pending.removeAll(keepingCapacity: false)
    }

    /// Runs on the render thread: resample, then cut [pending] into frames.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        // The resampler can emit a sample or two beyond what the rate ratio
        // predicts, depending on the phase it carries between buffers.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channels = out.int16ChannelData else { return }

        pending.append(contentsOf: UnsafeBufferPointer(
            start: channels[0],
            count: Int(out.frameLength)
        ))
        while pending.count >= Self.frameSamples {
            let frame = Array(pending.prefix(Self.frameSamples))
            pending.removeFirst(Self.frameSamples)
            emitFrame(frame.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(onConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        #if os(iOS)
        nc.addObserver(
            self,
            selector: #selector(onSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        #endif
    }

    @objc private func onConfigurationChange(_ notification: Notification) {
        interrupt("configurationChange")
    }

    #if os(iOS)
    @objc private func onSessionInterruption(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
        interrupt("interruption")
    }

    @objc private func onRouteChange(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        else { return }
        interrupt("routeChange")
    }
    #endif

    /// Notifications arrive on arbitrary threads; engine teardown and the
    /// sink both belong on main.
    private func interrupt(_ reason: String) {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.stopEngine()
            self.emitState("interrupted", reason: reason)
        }
    }

    private func emitFrame(_ pcm: Data) {
        DispatchQueue.main.async {
            self.eventSink?([
                "type": "frame",
                "pcm": FlutterStandardTypedData(bytes: pcm),
            ])
        }
    }

    /// Queued behind the frames already in flight, so Dart sees the last
    /// frame of a capture before the state that ends it.
    private func emitState(_ state: String, reason: String?) {
        var event: [String: Any] = ["type": "state", "state": state]
        if let reason { event["reason"] = reason }
        DispatchQueue.main.async { self.eventSink?(event) }
    }

    private func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }
}
