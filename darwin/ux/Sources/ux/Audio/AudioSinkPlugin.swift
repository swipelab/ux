import AVFoundation

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// `ux/audio_sink` + `ux/audio_sink/events`. Plays queued mono 16 kHz Int16
/// PCM through an `AVAudioPlayerNode`, converting to the float format the
/// engine's mixer takes and letting the mixer resample to the hardware rate.
///
/// The node is attached to the plugin's own engine and connected to the main
/// mixer, so the sink writes to the output without configuring the route. On
/// iOS it only ever *widens* the shared `AVAudioSession` category to include
/// playback (`AudioSession.upgradeForPlayback`) and never sets a mode or a
/// routing option, which leaves a call's `.voiceChat` route and its speaker
/// choice exactly as the call set them.
public class AudioSinkPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(
        standardFormatWithSampleRate: 16000,
        channels: 1
    )!

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var open = false
    private var pending = 0
    private var current = "idle"

    /// A buffer scheduled before a flush reports completion after it, carrying
    /// the epoch it was scheduled under: a stale one neither empties the queue
    /// nor drains it.
    private var epoch = 0

    public func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "ux/audio_sink",
            binaryMessenger: registrar.uxMessenger
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = methods

        let events = FlutterEventChannel(
            name: "ux/audio_sink/events",
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
        // A sink already playing when Dart subscribes would otherwise never
        // report the state it is in.
        emitState(current)
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "enqueue":
            guard let pcm = call.arguments as? FlutterStandardTypedData else {
                return result(FlutterError(
                    code: "start_failed",
                    message: "expected PCM bytes",
                    details: nil
                ))
            }
            enqueue(pcm.data, result: result)
        case "flush":
            flushQueue()
            emitState("idle")
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func enqueue(_ pcm: Data, result: @escaping FlutterResult) {
        guard let buffer = Self.buffer(from: pcm, format: playFormat) else {
            return result(nil)
        }
        if !open {
            // iOS-only category widening; the macOS build of `AudioSession`
            // is a no-op.
            AudioSession.upgradeForPlayback()
            if player.engine == nil { engine.attach(player) }
            // Reconnecting on every open is what re-establishes the graph
            // after a configuration change invalidated it.
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return result(FlutterError(
                    code: "start_failed",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
            player.play()
            open = true
        }

        if pending == 0 { emitState("playing") }
        pending += 1
        let scheduled = epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            DispatchQueue.main.async { self?.played(epoch: scheduled) }
        }
        result(nil)
    }

    /// Runs on main, where `pending` and `epoch` are also written.
    private func played(epoch: Int) {
        guard epoch == self.epoch else { return }
        pending -= 1
        guard pending == 0 else { return }
        emitDrained()
        emitState("idle")
    }

    private func flushQueue() {
        epoch += 1
        pending = 0
        guard open else { return }
        open = false
        player.stop()
        engine.stop()
    }

    /// Decodes little-endian Int16 into the engine's float format.
    private static func buffer(
        from pcm: Data,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                let sample = Int16(
                    littleEndian: raw.loadUnaligned(
                        fromByteOffset: i * 2,
                        as: Int16.self
                    )
                )
                channel[i] = Float(sample) / 32768.0
            }
        }
        return buffer
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
        #endif
    }

    /// The engine keeps running across some configuration changes — a new
    /// mixer format, a re-plugged device it can follow. Only one that stopped
    /// it has taken the output away.
    @objc private func onConfigurationChange(_ notification: Notification) {
        guard !engine.isRunning else { return }
        interrupt()
    }

    #if os(iOS)
    @objc private func onSessionInterruption(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
        interrupt()
    }
    #endif

    /// Notifications arrive on arbitrary threads; teardown and the sink both
    /// belong on main.
    private func interrupt() {
        DispatchQueue.main.async {
            guard self.open else { return }
            self.flushQueue()
            self.emitState("interrupted")
        }
    }

    private func emitDrained() {
        DispatchQueue.main.async { self.eventSink?(["type": "drained"]) }
    }

    /// Queued behind the completions already in flight, so Dart sees the drain
    /// of a queue before the state that follows it.
    private func emitState(_ state: String) {
        current = state
        DispatchQueue.main.async {
            self.eventSink?(["type": "state", "state": state])
        }
    }
}
