package io.swipelab.ux.camera

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import androidx.camera.core.MirrorMode
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import java.io.File
import java.util.UUID

/// Wraps CameraX `VideoCapture<Recorder>`. One per [CameraInstance];
/// the use case is bound alongside Preview + ImageCapture in
/// `CameraInstance.bind`. Telegram-fidelity mirror policy: raw sensor
/// feed in the recorded MP4 (no `MIRROR_MODE_ON_FRONT_ONLY` default
/// CameraX would otherwise apply).
class VideoCapture {
    private val recorder = Recorder.Builder()
        // HD (720p) matches iOS' AVCaptureSession.Preset.high default
        // negotiation for 1280×720; keeps file sizes reasonable for
        // chat composer use and well within the 3-use-case binding
        // budget for mid-range Android devices.
        .setQualitySelector(QualitySelector.from(Quality.HD))
        .build()

    val useCase: androidx.camera.video.VideoCapture<Recorder> =
        androidx.camera.video.VideoCapture.Builder(recorder)
            // Raw sensor capture — selfie videos are "as others see
            // you"; the preview-only mirror lives in XCameraPreview.
            .setMirrorMode(MirrorMode.MIRROR_MODE_OFF)
            .build()

    private var recording: Recording? = null
    private var stopCompletion: ((Result<String>) -> Unit)? = null
    private var outFile: File? = null

    val isRecording: Boolean get() = recording != null

    /// Begin recording into a UUID-named MP4 in [context]'s cache dir.
    /// [snapshotRotation] is a `Surface.ROTATION_*`. Audio is enabled
    /// only when [enableAudio] AND the RECORD_AUDIO permission is
    /// already granted — calling `withAudioEnabled()` without the
    /// permission throws `SecurityException`.
    ///
    /// [onStartResult] fires synchronously after `Recording.start()`
    /// returns (with success) — CameraX's `Recording` is "live" by
    /// then; the asynchronous Start/Status/Finalize events still flow
    /// to our listener but the caller has already moved on. Any
    /// failure raised by `start()` is surfaced as a failed result.
    /// The eventual Finalize event flows to the [stop] completion.
    @SuppressLint("MissingPermission")
    fun start(
        context: Context,
        enableAudio: Boolean,
        snapshotRotation: Int,
        onStartResult: (Result<Unit>) -> Unit,
    ) {
        if (recording != null) {
            onStartResult(Result.failure(
                IllegalStateException("Recording already in flight"),
            ))
            return
        }

        useCase.targetRotation = snapshotRotation

        val file = File(context.cacheDir, "ux_camera_${UUID.randomUUID()}.mp4")
        outFile = file
        val options = FileOutputOptions.Builder(file).build()

        val audioGranted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED

        var pending = recorder.prepareRecording(context, options)
        if (enableAudio && audioGranted) {
            pending = pending.withAudioEnabled()
        }

        try {
            recording = pending.start(
                ContextCompat.getMainExecutor(context),
            ) { event ->
                if (event is VideoRecordEvent.Finalize) {
                    val cb = stopCompletion
                    stopCompletion = null
                    recording = null
                    val target = outFile
                    outFile = null
                    if (event.hasError()) {
                        cb?.invoke(Result.failure(
                            RuntimeException(
                                "VideoRecordEvent.Finalize error " +
                                    "${event.error}: ${event.cause?.localizedMessage}",
                            ),
                        ))
                    } else {
                        cb?.invoke(Result.success(target?.absolutePath ?: ""))
                    }
                }
            }
            onStartResult(Result.success(Unit))
        } catch (t: Throwable) {
            recording = null
            outFile = null
            onStartResult(Result.failure(t))
        }
    }

    /// Stop the in-flight recording. [onResult] fires when the
    /// Finalize event lands — typically within ~100–300 ms of the
    /// stop call. If no recording is in flight, fires failure.
    fun stop(onResult: (Result<String>) -> Unit) {
        val r = recording
        if (r == null) {
            onResult(Result.failure(IllegalStateException("No recording in flight")))
            return
        }
        // Stash the completion BEFORE telling the recorder to stop —
        // the Finalize callback can fire before `stop()` returns on
        // fast hardware.
        stopCompletion = onResult
        r.stop()
    }

    /// Drop any in-flight recording without delivering its file.
    /// Used by [CameraInstance.dispose] when the instance is torn
    /// down mid-recording — mirrors the iOS path's `recorder.cancel()`.
    fun cancel() {
        val r = recording
        if (r != null) {
            recording = null
            r.stop()
        }
        stopCompletion?.invoke(Result.failure(
            RuntimeException("Recording cancelled"),
        ))
        stopCompletion = null
        outFile?.delete()
        outFile = null
    }
}
