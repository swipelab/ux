package io.swipelab.ux.camera

import android.content.Context
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.core.content.ContextCompat
import java.io.File
import java.util.UUID

/// Wraps CameraX [ImageCapture]. Per-shot `setTargetRotation(snapshot)`
/// stamps the rotation into the JPEG's EXIF, matching the iOS plugin's
/// `AVCapturePhotoOutput.connection.videoOrientation` per-shot pattern.
class PhotoCapture {
    val useCase: ImageCapture = ImageCapture.Builder()
        .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
        .setJpegQuality(92)
        .build()

    var flashMode: Int
        get() = useCase.flashMode
        set(value) { useCase.flashMode = value }

    /// Snap a still. [snapshotRotation] is a `Surface.ROTATION_*` value.
    /// [onResult] fires on the main thread with the saved file path or
    /// the error.
    fun take(
        context: Context,
        snapshotRotation: Int,
        onResult: (Result<String>) -> Unit,
    ) {
        useCase.targetRotation = snapshotRotation

        val outFile = File(context.cacheDir, "ux_camera_${UUID.randomUUID()}.jpg")
        val options = ImageCapture.OutputFileOptions.Builder(outFile).build()

        useCase.takePicture(
            options,
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    onResult(Result.success(outFile.absolutePath))
                }

                override fun onError(exc: ImageCaptureException) {
                    onResult(Result.failure(exc))
                }
            },
        )
    }
}
