package io.swipelab.ux.screen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.swipelab.ux.notificationIcon

/// A hold the platform refused, carrying the code Dart raises.
internal data class ScreenShareFailure(val code: String, val message: String?)

/// The `mediaProjection` foreground service a screen share runs inside.
/// Android grants `createVirtualDisplay` only while it is up, and grants the
/// service itself only once the projection consent is held — so it starts
/// between the two, and the capturer's own consent is what makes [start]
/// succeed.
@RequiresApi(Build.VERSION_CODES.Q)
class ScreenShareService : Service() {
    companion object {
        private const val NOTIFICATION_ID = 0x5CE1
        private const val CHANNEL_ID = "screen_share"
        private const val CHANNEL_NAME = "Screen sharing"
        private const val EXTRA_TITLE = "io.swipelab.ux.share.title"
        private const val EXTRA_TEXT = "io.swipelab.ux.share.text"

        private var pending: ((ScreenShareFailure?) -> Unit)? = null

        internal fun start(
            context: Context,
            title: String?,
            text: String?,
            onStarted: (ScreenShareFailure?) -> Unit,
        ) {
            settle(ScreenShareFailure("service_start_failed", "superseded"))
            pending = onStarted
            val intent = Intent(context, ScreenShareService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            try {
                context.startForegroundService(intent)
            } catch (e: SecurityException) {
                settle(ScreenShareFailure("permission_denied", e.message))
            } catch (e: IllegalStateException) {
                settle(ScreenShareFailure("service_start_failed", e.message))
            }
        }

        internal fun stop(context: Context) {
            settle(ScreenShareFailure("service_start_failed", "stopped"))
            context.stopService(Intent(context, ScreenShareService::class.java))
        }

        private fun settle(failure: ScreenShareFailure?) {
            val callback = pending ?: return
            pending = null
            callback(failure)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification(
            intent?.getStringExtra(EXTRA_TITLE).orEmpty(),
            intent?.getStringExtra(EXTRA_TEXT),
        )
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } catch (e: SecurityException) {
            settle(ScreenShareFailure("permission_denied", e.message))
            stopSelf(startId)
            return START_NOT_STICKY
        } catch (e: IllegalStateException) {
            settle(ScreenShareFailure("service_start_failed", e.message))
            stopSelf(startId)
            return START_NOT_STICKY
        }
        settle(null)
        return START_NOT_STICKY
    }

    private fun notification(title: String, text: String?): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(notificationIcon(this))
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}
