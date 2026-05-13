package io.swipelab.ux

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.Executors

class ScannerPlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler {
    companion object {
        // Single shared event sink — the app only ever shows one scanner
        // at a time (settings → scan), so collapsing to one channel keeps
        // the platform-view factory free of per-view registrar wiring.
        @JvmStatic
        @Volatile
        var eventSink: EventChannel.EventSink? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        /// EventChannel methods are @UiThread; the analyzer runs on a
        /// background pool. Bounce through the main looper.
        @JvmStatic
        fun emit(code: String) {
            mainHandler.post { eventSink?.success(code) }
        }

        private const val PERMISSION_REQUEST_CODE = 0xC1A0
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var lifecycleOwner: LifecycleOwner? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ec = EventChannel(binding.binaryMessenger, "ux/scanner/events")
        ec.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
        eventChannel = ec

        val mc = MethodChannel(binding.binaryMessenger, "ux/scanner")
        mc.setMethodCallHandler(this)
        methodChannel = mc

        binding.platformViewRegistry.registerViewFactory(
            "ux/scanner",
            ScannerViewFactory { lifecycleOwner },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        // The host app's MainActivity is a `FlutterActivity`, which extends
        // `LifecycleOwner` indirectly via `androidx.activity.ComponentActivity`.
        lifecycleOwner = binding.activity as? LifecycleOwner
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener { code, _, results ->
            if (code != PERMISSION_REQUEST_CODE) return@addRequestPermissionsResultListener false
            val granted = results.isNotEmpty() &&
                results[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
            true
        }
    }

    override fun onDetachedFromActivity() {
        lifecycleOwner = null
        activity = null
        activityBinding = null
        // If the activity tears down with a request still in flight, settle
        // it cleanly rather than leaking the Result.
        pendingPermissionResult?.success(false)
        pendingPermissionResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> handleRequestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        val act = activity
            ?: return result.error("no_activity", "plugin not attached to an activity", null)
        val granted = ContextCompat.checkSelfPermission(
            act, Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) return result.success(true)
        if (pendingPermissionResult != null) {
            return result.error("in_progress", "another permission request is in flight", null)
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.CAMERA),
            PERMISSION_REQUEST_CODE,
        )
    }
}

private class ScannerViewFactory(
    private val lifecycleOwnerProvider: () -> LifecycleOwner?,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return ScannerPlatformView(context, lifecycleOwnerProvider())
    }
}

private class ScannerPlatformView(
    context: Context,
    private val lifecycleOwner: LifecycleOwner?,
) : PlatformView {
    // COMPATIBLE forces a TextureView under the hood; SurfaceView (the
    // PERFORMANCE default) is its own window and won't composite under
    // Flutter overlays in hybrid composition.
    private val previewView = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    }
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val reader: MultiFormatReader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            ),
        )
    }
    private var cameraProvider: ProcessCameraProvider? = null
    private var disposed = false

    init {
        if (lifecycleOwner != null) bindCamera(context, lifecycleOwner)
    }

    private fun bindCamera(context: Context, lifecycleOwner: LifecycleOwner) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            if (disposed) return@addListener
            val provider = cameraProviderFuture.get()
            cameraProvider = provider

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }

            try {
                provider.unbindAll()
                provider.bindToLifecycle(
                    lifecycleOwner,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis,
                )
            } catch (_: Throwable) {
                // Permission denied / camera unavailable — preview stays
                // black. Caller surfaces a fallback (e.g. paste-hex).
            }
        }, androidx.core.content.ContextCompat.getMainExecutor(context))
    }

    private fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes.firstOrNull() ?: return
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
            val source = PlanarYUVLuminanceSource(
                bytes,
                plane.rowStride,
                image.height,
                0, 0,
                image.width, image.height,
                false,
            )
            val bitmap = BinaryBitmap(HybridBinarizer(source))
            val result = try {
                reader.decode(bitmap)
            } catch (_: Throwable) {
                null
            } finally {
                reader.reset()
            }
            val text = result?.text
            if (!text.isNullOrEmpty()) {
                ScannerPlugin.emit(text)
            }
        } finally {
            image.close()
        }
    }

    override fun getView(): View = previewView

    override fun dispose() {
        disposed = true
        cameraProvider?.unbindAll()
        cameraProvider = null
        analysisExecutor.shutdown()
    }
}
