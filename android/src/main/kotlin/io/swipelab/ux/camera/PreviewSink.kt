package io.swipelab.ux.camera

import android.graphics.SurfaceTexture
import android.view.Surface
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry
import android.content.Context

/// Glue between CameraX's [Preview] use-case and Flutter's
/// `FlutterTexture`. CameraX hands us a [SurfaceRequest] each time the
/// preview pipeline (re-)negotiates its resolution; we resize our
/// `SurfaceTexture` to match, wrap it in a `Surface`, and hand that
/// back via `request.provideSurface`.
///
/// The texture id is stable across resolution changes — the Dart side
/// keeps using the same `Texture(textureId: ...)` widget regardless of
/// what dimensions the camera negotiated.
class PreviewSink(
    registry: TextureRegistry,
    private val context: Context,
) {
    private val entry: TextureRegistry.SurfaceTextureEntry = registry.createSurfaceTexture()
    private val surfaceTexture: SurfaceTexture = entry.surfaceTexture()
    private var activeSurface: Surface? = null

    val textureId: Long get() = entry.id()
    var previewSize: android.util.Size = android.util.Size(0, 0)
        private set

    /// `Preview.SurfaceProvider` callback. Pass directly to
    /// `previewUseCase.setSurfaceProvider(sink::provideSurface)`.
    fun provideSurface(request: SurfaceRequest) {
        val res = request.resolution
        surfaceTexture.setDefaultBufferSize(res.width, res.height)
        previewSize = res

        // Tear down any prior surface BEFORE handing out the new one —
        // CameraX retains it until provideSurface's listener fires.
        activeSurface?.release()
        val surface = Surface(surfaceTexture)
        activeSurface = surface

        request.provideSurface(
            surface,
            ContextCompat.getMainExecutor(context),
        ) { result ->
            // Result reasons we care about:
            //  - RESULT_REQUEST_CANCELLED / RESULT_WILL_NOT_PROVIDE_SURFACE:
            //    CameraX won't use this surface, drop it.
            //  - RESULT_SURFACE_USED_SUCCESSFULLY: CameraX is done with it,
            //    safe to release.
            //  - RESULT_INVALID_SURFACE: same — release.
            //  - RESULT_SURFACE_ALREADY_PROVIDED: shouldn't happen, ignore.
            result.surface.release()
            if (activeSurface === result.surface) activeSurface = null
        }
    }

    /// Called on instance dispose. Releases the texture and any
    /// outstanding surface.
    fun release() {
        activeSurface?.release()
        activeSurface = null
        entry.release()
    }
}
