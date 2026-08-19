package io.swipelab.ux

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// A projection the platform refused, carrying the code Dart raises.
private data class ProjectionFailure(val code: String, val message: String?)

/// `ux/audio_capture` + `ux/audio_capture/events`. Reads a microphone, or
/// what the device plays, through `AudioRecord` at 16 kHz mono PCM16 — the
/// format Dart's `XAudioCapture` publishes — and pushes fixed-size frames to
/// Dart. The Apple counterpart is `AudioCapturePlugin.swift`.
///
/// A microphone reads `VOICE_COMMUNICATION`, with the platform echo canceller
/// attached to the session where the device offers one: the tap feeds live
/// transcription while the same device plays the room's audio, and playback
/// (remote voices, dubs) must not re-enter as local speech. A playback tap is
/// that output, so it reads it raw — no `VOICE_COMMUNICATION`, no canceller —
/// through the media projection [AudioProjectionService] holds.
class AudioCapturePlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val PERMISSION_REQUEST_CODE = 0xA0D1
        private const val PROJECTION_REQUEST_CODE = 0xA0D2
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
    private var pendingConsent: ((Int, Intent?) -> Unit)? = null

    private var record: AudioRecord? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var projection: MediaProjection? = null
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
        binding.addActivityResultListener { code, resultCode, data ->
            if (code != PROJECTION_REQUEST_CODE) {
                return@addActivityResultListener false
            }
            val cb = pendingConsent ?: return@addActivityResultListener true
            pendingConsent = null
            cb(resultCode, data)
            true
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
        // Settle a request left in flight so the Dart Future doesn't hang.
        pending?.invoke(false)
        pending = null
        pendingConsent?.invoke(Activity.RESULT_CANCELED, null)
        pendingConsent = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sources" -> result.success(AudioSources.wire(inputs(), playbackReady()))
            "start" -> start(call.argument<String>("sourceId"), result)
            "stop" -> {
                stopRecord()
                emitState("idle", null)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(sourceId: String?, result: MethodChannel.Result) {
        if (running) return result.success(null)
        when (val selection = AudioSources.select(sourceId, inputs(), playbackReady())) {
            AudioSelection.DefaultInput -> startMicrophone(null, result)
            is AudioSelection.Microphone -> startMicrophone(selection.deviceId, result)
            AudioSelection.Playback -> startPlayback(result)
            AudioSelection.Unknown -> result.error("unknown_source", sourceId, null)
        }
    }

    /// A `null` [deviceId] is the system's own choice of input.
    private fun startMicrophone(deviceId: Int?, result: MethodChannel.Result) {
        requestPermission { granted ->
            if (!granted) {
                return@requestPermission result.error(
                    "permission_denied", "microphone", null,
                )
            }
            val bufferBytes = bufferBytes()
            if (bufferBytes <= 0) {
                return@requestPermission result.error(
                    "no_input_device", "16 kHz mono PCM16 unavailable", null,
                )
            }
            val rec = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                return@requestPermission result.error(
                    "start_failed", "AudioRecord did not initialize", null,
                )
            }
            if (deviceId != null && !route(rec, deviceId)) {
                rec.release()
                return@requestPermission result.error(
                    "no_input_device", "device $deviceId", null,
                )
            }
            if (!begin(rec, cancelEcho = true)) {
                return@requestPermission result.error(
                    "start_failed", "AudioRecord did not start", null,
                )
            }
            result.success(null)
        }
    }

    private fun startPlayback(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return result.error("unsupported", "Android 10 or newer", null)
        }
        startPlaybackTap(result)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startPlaybackTap(result: MethodChannel.Result) {
        // Playback capture reads through AudioRecord, which the platform
        // gates on RECORD_AUDIO whatever it is pointed at.
        requestPermission { granted ->
            if (!granted) {
                return@requestPermission result.error(
                    "permission_denied", "microphone", null,
                )
            }
            requestProjection { projection, failure ->
                if (projection == null) {
                    releaseProjection()
                    return@requestProjection result.error(
                        failure?.code ?: "start_failed", failure?.message, null,
                    )
                }
                val rec = openPlaybackRecord(projection)
                if (rec == null) {
                    releaseProjection()
                    return@requestProjection result.error(
                        "start_failed", "AudioRecord did not initialize", null,
                    )
                }
                if (!begin(rec, cancelEcho = false)) {
                    releaseProjection()
                    return@requestProjection result.error(
                        "start_failed", "AudioRecord did not start", null,
                    )
                }
                result.success(null)
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun openPlaybackRecord(projection: MediaProjection): AudioRecord? {
        val bufferBytes = bufferBytes()
        if (bufferBytes <= 0) return null
        val capture = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val rec = AudioRecord.Builder()
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(bufferBytes)
            .setAudioPlaybackCaptureConfig(capture)
            .build()
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return null
        }
        return rec
    }

    /// Starts [rec] reading and publishes the frames it delivers, under the
    /// platform echo canceller when [cancelEcho] and the device offers one.
    private fun begin(rec: AudioRecord, cancelEcho: Boolean): Boolean {
        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            return false
        }
        if (cancelEcho && AcousticEchoCanceler.isAvailable()) {
            echoCanceler = AcousticEchoCanceler.create(rec.audioSessionId)?.apply {
                enabled = true
            }
        }
        record = rec
        running = true
        registerRecordingCallback()
        reader = Thread({ readLoop(rec) }, "ux-audio-capture").apply { start() }
        emitState("running", null)
        return true
    }

    /// Four frames of slack over the driver minimum, so a late reader loses
    /// latency rather than samples.
    private fun bufferBytes(): Int {
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return minBuffer
        return maxOf(minBuffer, FRAME_SAMPLES * 2 * 4)
    }

    private fun route(rec: AudioRecord, deviceId: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val device = devices().firstOrNull { it.id == deviceId } ?: return false
        return rec.setPreferredDevice(device)
    }

    private fun inputs(): List<AudioInput> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        return devices()
            .filter { AudioSources.isMicrophone(it.type) }
            .map {
                AudioInput(it.id, AudioSources.label(it.type, it.productName.toString()))
            }
    }

    private fun devices(): List<AudioDeviceInfo> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val manager = audioManager() ?: return emptyList()
        return manager.getDevices(AudioManager.GET_DEVICES_INPUTS).toList()
    }

    private fun playbackReady(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /// Asks for the projection this capture taps: the consent, then the
    /// foreground hold the platform grants it inside.
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun requestProjection(
        cb: (MediaProjection?, ProjectionFailure?) -> Unit,
    ) {
        val ctx = context
        val act = activity
        if (ctx == null || act == null) {
            return cb(null, ProjectionFailure("start_failed", "no activity"))
        }
        if (pendingConsent != null) {
            return cb(null, ProjectionFailure("start_failed", "consent in flight"))
        }
        val manager = ctx.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as? MediaProjectionManager
            ?: return cb(null, ProjectionFailure("unsupported", "no media projection"))
        pendingConsent = { resultCode, data ->
            if (resultCode != Activity.RESULT_OK || data == null) {
                cb(null, ProjectionFailure("permission_denied", "playback capture"))
            } else {
                AudioProjectionService.start(ctx) { failure ->
                    if (failure != null) {
                        cb(null, ProjectionFailure("start_failed", failure))
                    } else {
                        cb(openProjection(manager, resultCode, data), null)
                    }
                }
            }
        }
        act.startActivityForResult(
            manager.createScreenCaptureIntent(),
            PROJECTION_REQUEST_CODE,
        )
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun openProjection(
        manager: MediaProjectionManager,
        resultCode: Int,
        data: Intent,
    ): MediaProjection? {
        val opened = manager.getMediaProjection(resultCode, data) ?: return null
        opened.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() = interrupt("projectionStopped")
            },
            main,
        )
        projection = opened
        return opened
    }

    private fun releaseProjection() {
        projection?.stop()
        projection = null
        val ctx = context ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            AudioProjectionService.stop(ctx)
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

    private fun stopRecord() {
        if (!running) return
        running = false
        unregisterRecordingCallback()
        record?.stop()
        reader?.join()
        reader = null
        echoCanceler?.release()
        echoCanceler = null
        record?.release()
        record = null
        releaseProjection()
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
