package io.swipelab.ux.camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import io.swipelab.ux.NativePlugin

/// `ux/camera` + `ux/camera/events` registrar. Routes channel calls
/// to per-handle [CameraInstance]s. Phase 4a: photo capture +
/// preview + lifecycle. Video recording is wired in Phase 4b.
class CameraPlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val PERMISSION_REQUEST_CODE = 0xC2A0
    }

    private val main = Handler(Looper.getMainLooper())

    private var context: Context? = null
    private var textureRegistry: TextureRegistry? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermission: ((Boolean, String) -> Unit)? = null
    private var pendingPermissionKind: String = ""

    private val instances = mutableMapOf<Int, CameraInstance>()
    private var nextHandle = 1
    private val lensesInUse = mutableSetOf<String>()
    private var audioInUse: Boolean = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textureRegistry = binding.textureRegistry

        val mc = MethodChannel(binding.binaryMessenger, "ux/camera")
        mc.setMethodCallHandler(this)
        methodChannel = mc

        val ec = EventChannel(binding.binaryMessenger, "ux/camera/events")
        ec.setStreamHandler(this)
        eventChannel = ec
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Dispose any leftover instances synchronously so the host process
        // doesn't keep a CameraX binding alive past engine teardown.
        instances.values.forEach { it.dispose() }
        instances.clear()
        lensesInUse.clear()
        audioInUse = false

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        context = null
        textureRegistry = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener { code, permissions, results ->
            if (code != PERMISSION_REQUEST_CODE) {
                return@addRequestPermissionsResultListener false
            }
            // Camera grant gates the whole flow; mic is optional (we
            // tolerate a missing audio input gracefully). Match iOS.
            val cameraIndex = permissions.indexOf(Manifest.permission.CAMERA)
            val cameraGranted = cameraIndex >= 0 &&
                results.getOrNull(cameraIndex) == PackageManager.PERMISSION_GRANTED
            val cb = pendingPermission
            pendingPermission = null
            val kind = pendingPermissionKind
            pendingPermissionKind = ""
            cb?.invoke(cameraGranted, if (cameraGranted) "" else kind)
            true
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
        activityBinding = null
        // If a request is still pending when the activity tears down,
        // settle it as denied so the Dart Future doesn't hang.
        pendingPermission?.invoke(false, pendingPermissionKind)
        pendingPermission = null
        pendingPermissionKind = ""
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
            "availableCameras" -> handleAvailableCameras(result)
            "create" -> handleCreate(call, result)
            "initialize" -> handleInitialize(call, result)
            "dispose" -> handleDispose(call, result)
            "setDescription" -> handleSetDescription(call, result)
            "setFlashMode" -> handleSetFlashMode(call, result)
            "lockCaptureOrientation" -> result.success(null) // preview always portrait
            "unlockCaptureOrientation" -> result.success(null)
            "takePicture" -> handleTakePicture(call, result)
            "startVideoRecording" -> handleStartVideo(call, result)
            "stopVideoRecording" -> handleStopVideo(call, result)
            "audioPermissionStatus" -> result.success(isAudioGranted())
            "openSettings" -> handleOpenSettings(result)
            else -> result.notImplemented()
        }
    }

    private fun handleAvailableCameras(result: MethodChannel.Result) {
        val ctx = context ?: return result.error("no_context", "engine detached", null)
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            try {
                val provider = future.get()
                val cameras = mutableListOf<Map<String, Any>>()
                if (provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) {
                    cameras.add(describeLens("back", provider))
                }
                if (provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)) {
                    cameras.add(describeLens("front", provider))
                }
                result.success(cameras)
            } catch (t: Throwable) {
                result.error("no_camera", t.localizedMessage, null)
            }
        }, ContextCompat.getMainExecutor(ctx))
    }

    private fun describeLens(lens: String, provider: ProcessCameraProvider): Map<String, Any> {
        val selector = when (lens) {
            "front" -> CameraSelector.DEFAULT_FRONT_CAMERA
            else -> CameraSelector.DEFAULT_BACK_CAMERA
        }
        // `filter(...)` returns the matching `CameraInfo` list without
        // requiring a lifecycle bind.
        val infos = selector.filter(provider.availableCameraInfos)
        val sensorRotation = infos.firstOrNull()?.sensorRotationDegrees ?: 0
        return mapOf(
            "id" to lens,
            "lens" to lens,
            "sensorOrientation" to sensorRotation,
        )
    }

    private fun handleCreate(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: return result.error("bad_args", "create", null)
        val cameraId = args["cameraId"] as? String
            ?: return result.error("bad_args", "create", null)
        val enableAudio = args["enableAudio"] as? Boolean ?: false
        val ctx = context ?: return result.error("no_context", "engine detached", null)
        val registry = textureRegistry
            ?: return result.error("init_failed", "no texture registry", null)

        if (lensesInUse.contains(cameraId)) {
            return result.error("device_busy", cameraId, null)
        }
        if (enableAudio && audioInUse) {
            return result.error("audio_busy", null, null)
        }

        val handle = nextHandle++
        val instance = CameraInstance(handle, ctx, registry)
        instance.onEvent = { payload ->
            main.post { eventSink?.success(payload) }
        }
        instances[handle] = instance
        lensesInUse.add(cameraId)
        if (enableAudio) audioInUse = true

        instance.create(cameraId, enableAudio) { err ->
            if (err != null) {
                instances.remove(handle)
                lensesInUse.remove(cameraId)
                if (enableAudio) audioInUse = false
                result.error("init_failed", err.localizedMessage, null)
                return@create
            }
            result.success(mapOf(
                "handle" to handle,
                "textureId" to instance.textureId,
                "previewSize" to mapOf(
                    "width" to instance.previewSize.width.toDouble(),
                    "height" to instance.previewSize.height.toDouble(),
                ),
                "previewRotationQuarterTurns" to instance.previewRotationQuarterTurns,
            ))
        }
    }

    private fun handleInitialize(call: MethodCall, result: MethodChannel.Result) {
        withInstance(call, result) { instance ->
            // Camera permission gate. Mic is optional; only camera
            // denial fails the flow (matches iOS).
            val perms = mutableListOf(Manifest.permission.CAMERA)
            if (instance.audioClaimed) perms += Manifest.permission.RECORD_AUDIO
            requestPermissions(perms) { cameraGranted, kind ->
                if (!cameraGranted) {
                    return@requestPermissions result.error(
                        "permission_denied", kind, null,
                    )
                }
                instance.initialize()
                result.success(null)
            }
        }
    }

    private fun handleDispose(call: MethodCall, result: MethodChannel.Result) {
        withInstance(call, result) { instance ->
            // Release claims before the (synchronous) dispose so a
            // follow-up create can succeed even mid-teardown — matches
            // iOS's claim-release timing.
            lensesInUse.remove(instance.currentLens)
            if (instance.audioClaimed) audioInUse = false
            instances.remove(instance.handle)
            instance.dispose()
            result.success(null)
        }
    }

    private fun handleSetDescription(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: return result.error("bad_args", "setDescription", null)
        val newLens = args["cameraId"] as? String
            ?: return result.error("bad_args", "setDescription", null)
        withInstance(call, result) { instance ->
            val oldLens = instance.currentLens
            if (oldLens != newLens && lensesInUse.contains(newLens)) {
                return@withInstance result.error("device_busy", newLens, null)
            }
            lensesInUse.add(newLens)
            try {
                val size = instance.setDescription(newLens)
                if (oldLens != newLens) lensesInUse.remove(oldLens)
                result.success(mapOf(
                    "previewSize" to mapOf(
                        "width" to size.width.toDouble(),
                        "height" to size.height.toDouble(),
                    ),
                    "previewRotationQuarterTurns" to instance.previewRotationQuarterTurns,
                ))
            } catch (t: Throwable) {
                if (oldLens != newLens) lensesInUse.remove(newLens)
                result.error("init_failed", t.localizedMessage, null)
            }
        }
    }

    private fun handleSetFlashMode(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: return result.error("bad_args", "setFlashMode", null)
        val mode = args["mode"] as? String ?: "off"
        withInstance(call, result) { instance ->
            instance.setFlashMode(mode)
            result.success(null)
        }
    }

    private fun handleTakePicture(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: return result.error("bad_args", "takePicture", null)
        val snapshotRaw = args["snapshotOrientation"] as? String ?: "portraitUp"
        withInstance(call, result) { instance ->
            instance.takePicture(flutterToSurfaceRotation(snapshotRaw)) { outcome ->
                outcome.fold(
                    onSuccess = { path -> result.success(mapOf("path" to path)) },
                    onFailure = { t ->
                        result.error("take_picture_failed", t.localizedMessage, null)
                    },
                )
            }
        }
    }

    private fun handleStartVideo(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
            ?: return result.error("bad_args", "startVideoRecording", null)
        val snapshotRaw = args["snapshotOrientation"] as? String ?: "portraitUp"
        withInstance(call, result) { instance ->
            instance.startVideoRecording(flutterToSurfaceRotation(snapshotRaw)) {
                outcome ->
                outcome.fold(
                    onSuccess = { result.success(null) },
                    onFailure = { t ->
                        result.error("recorder_failed", t.localizedMessage, null)
                    },
                )
            }
        }
    }

    private fun handleStopVideo(call: MethodCall, result: MethodChannel.Result) {
        withInstance(call, result) { instance ->
            instance.stopVideoRecording { outcome ->
                outcome.fold(
                    onSuccess = { path -> result.success(mapOf("path" to path)) },
                    onFailure = { t ->
                        result.error("recorder_failed", t.localizedMessage, null)
                    },
                )
            }
        }
    }

    private fun handleOpenSettings(result: MethodChannel.Result) {
        val act = activity
            ?: return result.error("no_activity", "plugin not attached", null)
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", act.packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        act.startActivity(intent)
        result.success(null)
    }

    private fun isAudioGranted(): Boolean {
        val ctx = context ?: return false
        return ContextCompat.checkSelfPermission(
            ctx, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermissions(
        perms: List<String>,
        cb: (Boolean, String) -> Unit,
    ) {
        val act = activity ?: return cb(false, "camera")
        val toRequest = perms.filter {
            ContextCompat.checkSelfPermission(act, it) !=
                PackageManager.PERMISSION_GRANTED
        }
        if (toRequest.isEmpty()) return cb(true, "")
        if (pendingPermission != null) {
            return cb(false, "camera") // serialize
        }
        pendingPermission = cb
        pendingPermissionKind = if (toRequest.contains(Manifest.permission.CAMERA))
            "camera" else "microphone"
        ActivityCompat.requestPermissions(
            act,
            toRequest.toTypedArray(),
            PERMISSION_REQUEST_CODE,
        )
    }

    private inline fun withInstance(
        call: MethodCall,
        result: MethodChannel.Result,
        body: (CameraInstance) -> Unit,
    ) {
        val args = call.arguments as? Map<*, *>
            ?: return result.error("bad_args", "missing handle", null)
        val handle = (args["handle"] as? Number)?.toInt()
            ?: return result.error("bad_args", "missing handle", null)
        val instance = instances[handle]
            ?: return result.error("disposed", "no camera for handle $handle", null)
        body(instance)
    }
}
