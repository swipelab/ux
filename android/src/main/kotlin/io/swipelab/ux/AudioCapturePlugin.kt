package io.swipelab.ux

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// `ux/audio_capture` + `ux/audio_capture/events`. Reads the microphone
/// through `AudioRecord` at 16 kHz mono PCM16 — the format Dart's
/// `XAudioCapture` publishes — and pushes fixed-size frames to Dart.
/// The Apple counterpart is `AudioCapturePlugin.swift`.
///
/// `VOICE_RECOGNITION` is the source: it asks for the speech-tuned input
/// chain (noise suppression where the device offers it, no AGC surprises)
/// and does not claim the communication route a call already holds.
class AudioCapturePlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val PERMISSION_REQUEST_CODE = 0xA0D1
        private const val SAMPLE_RATE = 16000

        /// Samples per emitted frame — 20 ms at [SAMPLE_RATE].
        private const val FRAME_SAMPLES = 320
    }

    private val main = Handler(Looper.getMainLooper())

    private var context: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var pending: ((Boolean) -> Unit)? = null

    private var record: AudioRecord? = null
    private var reader: Thread? = null

    @Volatile
    private var running = false

    /// `isClientSilenced` is how Android reports "something with higher
    /// priority took the microphone" — the recorder keeps reading, but the
    /// samples are zeros.
    private val recordingCallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(
                configs: MutableList<AudioRecordingConfiguration>,
            ) {
                val sessionId = record?.audioSessionId ?: return
                val mine = configs.firstOrNull {
                    it.clientAudioSessionId == sessionId
                } ?: return
                if (mine.isClientSilenced) interrupt("silenced")
            }
        }
    } else {
        null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        val mc = MethodChannel(binding.binaryMessenger, "ux/audio_capture")
        mc.setMethodCallHandler(this)
        methodChannel = mc

        val ec = EventChannel(binding.binaryMessenger, "ux/audio_capture/events")
        ec.setStreamHandler(this)
        eventChannel = ec
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopRecord()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener { code, permissions, results ->
            if (code != PERMISSION_REQUEST_CODE) {
                return@addRequestPermissionsResultListener false
            }
            val cb = pending ?: return@addRequestPermissionsResultListener true
            pending = null
            val idx = permissions.indexOf(Manifest.permission.RECORD_AUDIO)
            cb(idx >= 0 && results.getOrNull(idx) == PackageManager.PERMISSION_GRANTED)
            true
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
        // Settle a request left in flight so the Dart Future doesn't hang.
        pending?.invoke(false)
        pending = null
    }

    // MARK: - EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // MARK: - MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "stop" -> {
                stopRecord()
                emitState("idle", null)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (running) return result.success(null)
        requestPermission { granted ->
            if (!granted) {
                return@requestPermission result.error(
                    "permission_denied", "microphone", null,
                )
            }
            val minBuffer = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuffer <= 0) {
                return@requestPermission result.error(
                    "no_input_device", "16 kHz mono PCM16 unavailable", null,
                )
            }
            val rec = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                // Four frames of slack over the driver minimum, so a late
                // reader loses latency rather than samples.
                maxOf(minBuffer, FRAME_SAMPLES * 2 * 4),
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                return@requestPermission result.error(
                    "start_failed", "AudioRecord did not initialize", null,
                )
            }
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                rec.release()
                return@requestPermission result.error(
                    "start_failed", "AudioRecord did not start", null,
                )
            }
            record = rec
            running = true
            registerRecordingCallback()
            reader = Thread({ readLoop(rec) }, "ux-audio-capture").apply { start() }
            emitState("running", null)
            result.success(null)
        }
    }

    private fun readLoop(rec: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val samples = ShortArray(FRAME_SAMPLES)
        while (running) {
            var offset = 0
            while (offset < FRAME_SAMPLES && running) {
                val read = rec.read(samples, offset, FRAME_SAMPLES - offset)
                if (read < 0) {
                    interrupt("readError")
                    return
                }
                offset += read
            }
            if (offset == FRAME_SAMPLES) emitFrame(samples)
        }
    }

    /// Never called from the reader thread — it signals through [interrupt],
    /// so joining it here is safe.
    private fun stopRecord() {
        if (!running) return
        running = false
        unregisterRecordingCallback()
        reader?.join()
        reader = null
        record?.let {
            it.stop()
            it.release()
        }
        record = null
    }

    /// Reported from the recording callback and from the reader thread;
    /// teardown belongs on main, where `stop` also runs.
    private fun interrupt(reason: String) {
        main.post {
            if (!running) return@post
            stopRecord()
            emitState("interrupted", reason)
        }
    }

    private fun registerRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val cb = recordingCallback ?: return
        audioManager()?.registerAudioRecordingCallback(cb, main)
    }

    private fun unregisterRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val cb = recordingCallback ?: return
        audioManager()?.unregisterAudioRecordingCallback(cb)
    }

    private fun audioManager(): AudioManager? =
        context?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    // MARK: - Emission

    private fun emitFrame(samples: ShortArray) {
        val pcm = ByteBuffer.allocate(samples.size * 2)
            .order(ByteOrder.LITTLE_ENDIAN)
            .apply { asShortBuffer().put(samples) }
            .array()
        main.post { eventSink?.success(mapOf("type" to "frame", "pcm" to pcm)) }
    }

    private fun emitState(state: String, reason: String?) {
        val event = mutableMapOf<String, Any>("type" to "state", "state" to state)
        if (reason != null) event["reason"] = reason
        main.post { eventSink?.success(event) }
    }

    private fun requestPermission(cb: (Boolean) -> Unit) {
        val ctx = context ?: return cb(false)
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return cb(true)
        }
        val act = activity ?: return cb(false)
        if (pending != null) return cb(false)
        pending = cb
        ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST_CODE,
        )
    }
}
