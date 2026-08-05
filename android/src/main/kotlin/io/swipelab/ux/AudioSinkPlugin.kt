package io.swipelab.ux

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/// `ux/audio_sink` + `ux/audio_sink/events`. Streams queued mono 16 kHz PCM16
/// into an `AudioTrack` in `MODE_STREAM` — the format Dart's `XAudioSink`
/// publishes. The Apple counterpart is `AudioSinkPlugin.swift`.
///
/// `USAGE_MEDIA` + `CONTENT_TYPE_SPEECH` keeps the track on the media stream
/// instead of the communication one a call holds, and the sink never requests
/// audio focus: it neither ducks nor pauses whatever is already playing, and
/// nothing about a call's route changes when it opens. A consumer that wants
/// exclusive playback asks for focus itself.
class AudioSinkPlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val SAMPLE_RATE = 16000

        /// How long the writer waits for the next chunk before checking
        /// whether the device has played out everything handed to it.
        private const val POLL_MS = 10L
    }

    private val main = Handler(Looper.getMainLooper())

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private val queue = LinkedBlockingQueue<ByteArray>()
    private var track: AudioTrack? = null
    private var writer: Thread? = null

    @Volatile
    private var open = false

    /// Whether a queue is outstanding. Read and written on main only, so an
    /// enqueue racing the writer's playout report always wins.
    private var playing = false

    private var current = "idle"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val mc = MethodChannel(binding.binaryMessenger, "ux/audio_sink")
        mc.setMethodCallHandler(this)
        methodChannel = mc

        val ec = EventChannel(binding.binaryMessenger, "ux/audio_sink/events")
        ec.setStreamHandler(this)
        eventChannel = ec
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flushQueue()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // A sink already playing when Dart subscribes would otherwise never
        // report the state it is in.
        emitState(current)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enqueue" -> enqueue(call.arguments as? ByteArray, result)
            "flush" -> {
                flushQueue()
                emitState("idle")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun enqueue(pcm: ByteArray?, result: MethodChannel.Result) {
        if (pcm == null) {
            return result.error("start_failed", "expected PCM bytes", null)
        }
        if (pcm.size < 2) return result.success(null)
        if (!open) {
            val minBuffer = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuffer <= 0) {
                return result.error(
                    "no_output_device", "16 kHz mono PCM16 unavailable", null,
                )
            }
            val built = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(minBuffer)
                .build()
            if (built.state != AudioTrack.STATE_INITIALIZED) {
                built.release()
                return result.error(
                    "start_failed", "AudioTrack did not initialize", null,
                )
            }
            built.play()
            track = built
            open = true
            queue.clear()
            writer = Thread({ writeLoop(built) }, "ux-audio-sink").apply { start() }
        }
        queue.put(pcm)
        if (!playing) {
            playing = true
            emitState("playing")
        }
        result.success(null)
    }

    /// Hands chunks to the track, then watches the playback head so the drain
    /// is reported when the device has rendered them, not when the last write
    /// returned.
    private fun writeLoop(track: AudioTrack) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        var written = 0
        var reported = true
        while (open) {
            val chunk = queue.poll(POLL_MS, TimeUnit.MILLISECONDS)
            if (chunk == null) {
                if (!reported && track.playbackHeadPosition >= written) {
                    reported = true
                    main.post { reportDrained() }
                }
                continue
            }
            reported = false
            val count = track.write(chunk, 0, chunk.size)
            if (count < 0) return interrupt()
            written += count / 2
        }
    }

    private fun reportDrained() {
        if (!playing || queue.isNotEmpty()) return
        playing = false
        emitDrained()
        emitState("idle")
    }

    private fun flushQueue() {
        playing = false
        if (!open) return
        open = false
        queue.clear()
        // Unblock the writer sitting inside `write` before joining it.
        track?.pause()
        track?.flush()
        writer?.join()
        writer = null
        track?.stop()
        track?.release()
        track = null
    }

    /// Reported from the writer thread; teardown belongs on main, where
    /// `flush` also runs.
    private fun interrupt() {
        main.post {
            if (!open) return@post
            flushQueue()
            emitState("interrupted")
        }
    }

    private fun emitDrained() {
        main.post { eventSink?.success(mapOf("type" to "drained")) }
    }

    private fun emitState(state: String) {
        current = state
        main.post { eventSink?.success(mapOf("type" to "state", "state" to state)) }
    }
}
