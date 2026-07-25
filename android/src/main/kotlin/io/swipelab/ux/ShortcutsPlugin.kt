package io.swipelab.ux

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Rect
import androidx.core.app.Person
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Dynamic shortcuts, donated so the OS share sheet can offer the caller's
/// conversations as **Direct Share** targets.
///
/// The donated set is the caller's ordered list, replaced wholesale — ranking
/// is list order. Each shortcut is long-lived and carries a [Person] and a
/// [LocusIdCompat] keyed by the caller's id, which is what lets the system
/// rank and re-surface it. The `category` must be the one the consuming app's
/// `share-targets.xml` declares, or the sheet shows nothing.
///
/// A shortcut's own intent (what a launcher tap fires) is the package launch
/// intent; the share sheet ignores it and starts the `<share-target>` activity
/// with `EXTRA_SHORTCUT_ID` instead.
class ShortcutsPlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/shortcuts").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "donate" -> handleDonate(call, result)
            "clear" -> handleClear(result)
            else -> result.notImplemented()
        }
    }

    private fun handleDonate(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("no_context", "plugin is detached", null)
        val category = call.argument<String>("category")
            ?: return result.error("bad_args", "category is required", null)
        val targets = call.argument<List<Map<String, Any?>>>("targets")
            ?: return result.error("bad_args", "targets is required", null)

        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent(Intent.ACTION_MAIN).setPackage(ctx.packageName)
        val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(ctx)
        val shortcuts = targets.take(max).mapIndexedNotNull { rank, target ->
            val id = target["id"] as? String ?: return@mapIndexedNotNull null
            val label = target["label"] as? String ?: return@mapIndexedNotNull null
            val person = Person.Builder()
                .setName(label)
                .setKey(id)
                .setBot(false)
                .build()
            ShortcutInfoCompat.Builder(ctx, id)
                .setShortLabel(label)
                .setLongLabel(label)
                .setIntent(launch)
                .setRank(rank)
                .setLongLived(true)
                .setCategories(setOf(category))
                .setPerson(person)
                .setLocusId(LocusIdCompat(id))
                .apply { icon(target["iconPath"] as? String)?.let { setIcon(it) } }
                .build()
        }
        ShortcutManagerCompat.setDynamicShortcuts(ctx, shortcuts)
        result.success(null)
    }

    private fun handleClear(result: MethodChannel.Result) {
        val ctx = context ?: return result.error("no_context", "plugin is detached", null)
        ShortcutManagerCompat.removeAllDynamicShortcuts(ctx)
        result.success(null)
    }

    /// Square, centre-cropped adaptive icon from [path]. Adaptive is what the
    /// launcher masks to a circle for people shortcuts; a decode miss means no
    /// icon, and the app icon stands in.
    private fun icon(path: String?): IconCompat? {
        if (path == null || !File(path).isFile) return null
        val source = BitmapFactory.decodeFile(path) ?: return null
        try {
            val edge = minOf(source.width, source.height)
            if (edge <= 0) return null
            val square = Bitmap.createBitmap(edge, edge, Bitmap.Config.ARGB_8888)
            Canvas(square).drawBitmap(
                source,
                Rect(
                    (source.width - edge) / 2,
                    (source.height - edge) / 2,
                    (source.width - edge) / 2 + edge,
                    (source.height - edge) / 2 + edge,
                ),
                Rect(0, 0, edge, edge),
                null,
            )
            return IconCompat.createWithAdaptiveBitmap(square)
        } finally {
            source.recycle()
        }
    }
}
