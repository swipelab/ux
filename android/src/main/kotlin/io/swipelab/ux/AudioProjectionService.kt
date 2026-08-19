package io.swipelab.ux

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

/// The `mediaProjection` foreground service a playback capture runs inside.
/// Android grants the projection only while it is up, and grants the service
/// itself only once the capture consent is held — so it starts between the
/// two. It is the audio tap's own hold: `ScreenShareService` brackets a
/// screen share, and neither hold stands in for the other.
@RequiresApi(Build.VERSION_CODES.Q)
class AudioProjectionService : Service() {
    companion object {
        private const val NOTIFICATION_ID = 0xA0D2
        private const val CHANNEL_ID = "audio_capture"
        private const val CHANNEL_NAME = "Audio capture"

        private var pending: ((String?) -> Unit)? = null

        /// Brings the hold up, answering the failure that kept it down or
        /// `null` once it stands.
        internal fun start(context: Context, onStarted: (String?) -> Unit) {
            settle("superseded")
            pending = onStarted
            try {
                context.startForegroundService(
                    Intent(context, AudioProjectionService::class.java),
                )
            } catch (e: SecurityException) {
                settle(e.message ?: "denied")
            } catch (e: IllegalStateException) {
                settle(e.message ?: "refused")
            }
        }

        internal fun stop(context: Context) {
            settle("stopped")
            context.stopService(Intent(context, AudioProjectionService::class.java))
        }

        private fun settle(failure: String?) {
            val callback = pending ?: return
            pending = null
            callback(failure)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } catch (e: SecurityException) {
            settle(e.message ?: "denied")
            stopSelf(startId)
            return START_NOT_STICKY
        } catch (e: IllegalStateException) {
            settle(e.message ?: "refused")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        settle(null)
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
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
            .setContentTitle(applicationInfo.loadLabel(packageManager).toString())
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}
