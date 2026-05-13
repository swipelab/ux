package io.swipelab.ux.camera

import android.content.Context
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry

/// One per `UxCameraController` on the Dart side. Owns CameraX's
/// [ProcessCameraProvider] binding, the [PreviewSink] (texture +
/// SurfaceProvider), the [PhotoCapture] use-case, and the per-instance
/// [CustomLifecycleOwner] that drives them.
///
/// All public methods run on the main thread unless documented
/// otherwise. CameraX itself is thread-safe; the synchronization here
/// is just "don't reorder configure-vs-bind in confusing ways."
class CameraInstance(
    val handle: Int,
    private val context: Context,
    registry: TextureRegistry,
) {
    /// Pushed to Dart as `{event, handle, …}` payloads. Set by the
    /// plugin in [CameraPlugin.create].
    var onEvent: ((Map<String, Any?>) -> Unit)? = null

    private val lifecycleOwner = CustomLifecycleOwner()
    private val previewSink = PreviewSink(registry, context)
    private val photo = PhotoCapture()
    private val video = VideoCapture()
    private val orientation = DeviceOrientationBridge(context)

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null

    /// `back` / `front`. Set on create; updated on [setDescription].
    private var lens: String = "back"
    private var enableAudio: Boolean = false
    private var disposed = false

    val textureId: Long get() = previewSink.textureId
    val previewSize: Size get() = previewSink.previewSize
    val currentLens: String get() = lens
    val audioClaimed: Boolean get() = enableAudio

    /// Always 0 on Android: Flutter's `Texture` widget samples the
    /// underlying `SurfaceTexture` with its transform matrix applied
    /// (`GL_TEXTURE_EXTERNAL_OES` sampling reads
    /// `SurfaceTexture.getTransformMatrix()`), and CameraX populates
    /// that matrix with the rotation needed for upright display. Any
    /// `RotatedBox` on top of that would double-apply the rotation.
    /// The field stays in the wire protocol for iOS' sake (always 0
    /// there too, since AVCaptureConnection pre-rotates the sample
    /// buffers) and as a future hook if a non-CameraX preview path
    /// ever lands.
    val previewRotationQuarterTurns: Int get() = 0

    /// Bind the provider against [lens]. Resolves the
    /// [ProcessCameraProvider.getInstance] future on the main executor
    /// before invoking [onReady]. [onReady] fires with success or the
    /// thrown exception.
    fun create(
        lens: String,
        enableAudio: Boolean,
        onReady: (Throwable?) -> Unit,
    ) {
        check(!disposed)
        this.lens = lens
        this.enableAudio = enableAudio

        previewSink.onResize = { size ->
            emit(mapOf(
                "event" to "previewSizeChanged",
                "previewSize" to mapOf(
                    "width" to size.width.toDouble(),
                    "height" to size.height.toDouble(),
                ),
            ))
        }

        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (disposed) return@addListener
            try {
                val provider = future.get()
                cameraProvider = provider
                bind(provider)
                orientation.start { rot ->
                    emit(mapOf(
                        "event" to "deviceOrientationChanged",
                        "orientation" to surfaceRotationToFlutter(rot),
                    ))
                }
                onReady(null)
            } catch (t: Throwable) {
                onReady(t)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /// Move the lifecycle owner to STARTED — CameraX starts streaming
    /// preview frames + the [ImageCapture] use-case becomes ready.
    fun initialize() {
        check(!disposed)
        lifecycleOwner.start()
    }

    /// Idempotent teardown. Releases the texture, unbinds the provider,
    /// drops the lifecycle owner to DESTROYED.
    fun dispose() {
        if (disposed) return
        disposed = true
        // Mirror iOS' dispose: any in-flight recording is hard-cancelled
        // (file discarded) rather than left to flush, since there's no
        // caller waiting on the result anymore.
        if (video.isRecording) video.cancel()
        orientation.stop()
        cameraProvider?.unbindAll()
        cameraProvider = null
        camera = null
        preview = null
        previewSink.release()
        lifecycleOwner.destroy()
        onEvent = null
    }

    /// Swap the bound lens (front ↔ back). Re-binds the use-cases
    /// against the new [CameraSelector].
    fun setDescription(newLens: String): Size {
        check(!disposed)
        if (newLens == lens) return previewSink.previewSize
        lens = newLens
        cameraProvider?.let(::bind)
        return previewSink.previewSize
    }

    /// Flash mode for the next still capture. [mode] is `off` / `always`.
    /// Maps to `ImageCapture.FLASH_MODE_*`.
    fun setFlashMode(mode: String) {
        photo.flashMode = when (mode) {
            "always" -> ImageCapture.FLASH_MODE_ON
            else -> ImageCapture.FLASH_MODE_OFF
        }
    }

    fun takePicture(
        snapshotRotation: Int,
        onResult: (Result<String>) -> Unit,
    ) {
        check(!disposed)
        photo.take(context, snapshotRotation, onResult)
    }

    /// Begin recording. [snapshotRotation] is baked into the file's
    /// rotation metadata; the file plays back rotated even if the
    /// device returns to portrait mid-recording. [onStartResult] fires
    /// when CameraX's `Recording.start()` returns (immediately on
    /// success), not when the first frame lands.
    fun startVideoRecording(
        snapshotRotation: Int,
        onStartResult: (Result<Unit>) -> Unit,
    ) {
        check(!disposed)
        video.start(context, enableAudio, snapshotRotation, onStartResult)
    }

    /// Stop the in-flight recording. [onResult] fires asynchronously
    /// when CameraX delivers the Finalize event.
    fun stopVideoRecording(onResult: (Result<String>) -> Unit) {
        check(!disposed)
        video.stop(onResult)
    }

    private fun bind(provider: ProcessCameraProvider) {
        provider.unbindAll()

        val selector = when (lens) {
            "front" -> CameraSelector.DEFAULT_FRONT_CAMERA
            else -> CameraSelector.DEFAULT_BACK_CAMERA
        }

        val preview = Preview.Builder()
            // Preview pinned to portrait — recording / capture
            // orientation comes from the per-call `setTargetRotation`
            // on the photo / video use-case, never from the preview.
            .setTargetRotation(android.view.Surface.ROTATION_0)
            .build()
            .also { it.setSurfaceProvider(previewSink::provideSurface) }
        this.preview = preview

        // Preview + ImageCapture + VideoCapture as a single binding.
        // CameraX 1.4 supports this combination on essentially every
        // device that supports video — if a device can't deliver all
        // three simultaneously, `bindToLifecycle` throws and we'd
        // need to fall back. Not observed on Pixel-class hardware.
        camera = provider.bindToLifecycle(
            lifecycleOwner,
            selector,
            preview,
            photo.useCase,
            video.useCase,
        )
    }

    private fun emit(extras: Map<String, Any?>) {
        val payload = HashMap<String, Any?>(extras.size + 1)
        payload["handle"] = handle
        payload.putAll(extras)
        onEvent?.invoke(payload)
    }
}
