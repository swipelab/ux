package io.swipelab.ux

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/// `ux/notifications` + `ux/notifications/events`. Domain-agnostic OS
/// notification surface — show / cancel via the method channel, tap +
/// authorization changes via the event channel. The Apple counterpart is
/// `NotificationsPlugin.swift` (macOS only). App foreground/background state
/// lives in `WindowPlugin`, not here.
class NotificationsPlugin :
    NativePlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        private const val CHANNEL_ID = "messages"
        private const val CHANNEL_NAME = "Messages"
        private const val PERMISSION_REQUEST_CODE = 0xC3A0

        /// Host app points this at a white-silhouette status drawable
        /// (a coloured launcher icon renders as a white square). Falls
        /// back to the launcher icon when absent.
        private const val ICON_META = "io.swipelab.ux.notification_icon"

        /// Tap payload is carried back on the launch intent: a boolean
        /// marker plus one string extra per `data` entry, namespaced so it
        /// can't collide with the host app's own extras.
        private const val EXTRA_MARKER = "io.swipelab.ux.notif"
        private const val EXTRA_PREFIX = "io.swipelab.ux.notif."
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var context: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// A tap that cold-started the process arrives before Dart subscribes.
    /// Hold it until [onListen] gives us a sink, else the launch tap is lost.
    private var pendingTap: Map<String, String>? = null

    private val permissionListener =
        PluginRegistry.RequestPermissionsResultListener { code, _, results ->
            if (code != PERMISSION_REQUEST_CODE) {
                false
            } else {
                val granted = results.isNotEmpty() &&
                    results[0] == PackageManager.PERMISSION_GRANTED
                pendingPermissionResult?.success(granted)
                pendingPermissionResult = null
                emitAuthorization(granted)
                true
            }
        }

    private val newIntentListener = PluginRegistry.NewIntentListener { intent ->
        handleTapIntent(intent)
        false
    }

    // MARK: - Engine lifecycle

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        val mc = MethodChannel(binding.binaryMessenger, "ux/notifications")
        mc.setMethodCallHandler(this)
        methodChannel = mc

        val ec = EventChannel(binding.binaryMessenger, "ux/notifications/events")
        ec.setStreamHandler(this)
        eventChannel = ec
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        context = null
    }

    // MARK: - Activity lifecycle

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionListener)
        binding.addOnNewIntentListener(newIntentListener)
        // The activity may have been launched by a notification tap.
        handleTapIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionListener)
        activityBinding?.removeOnNewIntentListener(newIntentListener)
        activity = null
        activityBinding = null
        pendingPermissionResult?.success(false)
        pendingPermissionResult = null
    }

    // MARK: - EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val tap = pendingTap
        if (tap != null) {
            pendingTap = null
            events?.success(mapOf("type" to "tap", "data" to tap))
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // MARK: - MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> handleRequestPermission(result)
            "show" -> handleShow(call, result)
            "cancelByThread" -> handleCancelByThread(call, result)
            "cancelAll" -> handleCancelAll(result)
            else -> result.notImplemented()
        }
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        val ctx = context
            ?: return result.error("no_context", "engine detached", null)
        // Below 13 there is no runtime permission — notifications are on
        // unless the user disabled them in system settings.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val enabled = NotificationManagerCompat.from(ctx).areNotificationsEnabled()
            emitAuthorization(enabled)
            return result.success(enabled)
        }
        val act = activity
            ?: return result.error("no_activity", "plugin not attached to an activity", null)
        val granted = ContextCompat.checkSelfPermission(
            act, Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            emitAuthorization(true)
            return result.success(true)
        }
        if (pendingPermissionResult != null) {
            return result.error("in_progress", "another permission request is in flight", null)
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE,
        )
    }

    private fun handleShow(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
            ?: return result.error("no_context", "engine detached", null)
        val id = call.argument<String>("id")
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        if (id == null || title == null || body == null) {
            return result.error("bad_args", "show expects id/title/body", null)
        }
        val threadId = call.argument<String>("threadId")
        val data = call.argument<Map<String, Any?>>("data")
            ?.mapValues { it.value?.toString() ?: "" } ?: emptyMap()

        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) {
            emitAuthorization(false)
            return result.success(null)
        }
        post(ctx, id, title, body, threadId, data)
        result.success(null)
    }

    private fun post(
        ctx: Context,
        id: String,
        title: String,
        body: String,
        threadId: String?,
        data: Map<String, String>,
    ) {
        ensureChannel(ctx)

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pending = PendingIntent.getActivity(
            ctx, id.hashCode(), buildLaunchIntent(ctx, data), flags,
        )

        val builder = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(smallIcon(ctx))
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pending)
        if (threadId != null) builder.setGroup(threadId)

        // Same (tag, id) replaces — `id` is stable per message, so a fresh
        // preview supersedes the older toast. areNotificationsEnabled() was
        // checked by the caller, so POST_NOTIFICATIONS is satisfied.
        NotificationManagerCompat.from(ctx).notify(id, 0, builder.build())
    }

    private fun handleCancelByThread(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
            ?: return result.error("no_context", "engine detached", null)
        val threadId = call.argument<String>("threadId")
            ?: return result.error("bad_args", "cancelByThread expects threadId", null)
        // getActiveNotifications (used to recover the group key per notification)
        // is API 23+; below that there is no way to enumerate, so it's a no-op.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            for (sbn in mgr.activeNotifications) {
                if (sbn.notification.group == threadId) {
                    val tag = sbn.tag
                    if (tag != null) mgr.cancel(tag, sbn.id) else mgr.cancel(sbn.id)
                }
            }
        }
        result.success(null)
    }

    private fun handleCancelAll(result: MethodChannel.Result) {
        val ctx = context
            ?: return result.error("no_context", "engine detached", null)
        NotificationManagerCompat.from(ctx).cancelAll()
        result.success(null)
    }

    // MARK: - Tap routing

    private fun handleTapIntent(intent: Intent?) {
        val i = intent ?: return
        if (!i.getBooleanExtra(EXTRA_MARKER, false)) return
        val extras = i.extras ?: return
        val data = HashMap<String, String>()
        for (key in extras.keySet()) {
            if (key.startsWith(EXTRA_PREFIX)) {
                data[key.removePrefix(EXTRA_PREFIX)] = extras.getString(key) ?: ""
            }
        }
        emitTap(data)
    }

    private fun buildLaunchIntent(ctx: Context, data: Map<String, String>): Intent {
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent(Intent.ACTION_MAIN)
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.putExtra(EXTRA_MARKER, true)
        for ((k, v) in data) launch.putExtra(EXTRA_PREFIX + k, v)
        return launch
    }

    // MARK: - Helpers

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH),
        )
    }

    private fun smallIcon(ctx: Context): Int {
        val ai = ctx.packageManager.getApplicationInfo(
            ctx.packageName, PackageManager.GET_META_DATA,
        )
        val meta = ai.metaData?.getInt(ICON_META, 0) ?: 0
        return if (meta != 0) meta else ai.icon
    }

    private fun emitTap(data: Map<String, String>) {
        val sink = eventSink
        if (sink == null) {
            pendingTap = data
            return
        }
        mainHandler.post { sink.success(mapOf("type" to "tap", "data" to data)) }
    }

    private fun emitAuthorization(granted: Boolean) {
        mainHandler.post {
            eventSink?.success(mapOf("type" to "authorization", "granted" to granted))
        }
    }
}
