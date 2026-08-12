package io.swipelab.ux

import android.content.Context
import android.content.pm.PackageManager

/// Host app points `io.swipelab.ux.notification_icon` meta-data at a
/// white-silhouette status drawable (a coloured launcher icon renders as a
/// white square). Falls back to the launcher icon when absent.
internal fun notificationIcon(context: Context): Int {
    val info = context.packageManager.getApplicationInfo(
        context.packageName, PackageManager.GET_META_DATA,
    )
    val meta = info.metaData?.getInt("io.swipelab.ux.notification_icon", 0) ?: 0
    return if (meta != 0) meta else info.icon
}
