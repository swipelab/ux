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

        camera = provider.bindToLifecycle(
            lifecycleOwner,
            selector,
            preview,
            photo.useCase,
        )
    }

    private fun emit(extras: Map<String, Any?>) {
        val payload = HashMap<String, Any?>(extras.size + 1)
        payload["handle"] = handle
        payload.putAll(extras)
        onEvent?.invoke(payload)
    }
}
