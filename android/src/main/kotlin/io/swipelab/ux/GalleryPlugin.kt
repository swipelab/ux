package io.swipelab.ux

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/// `MediaStore` bridge for `XGallery` — paginated photo + video
/// queries via `ContentResolver`, cell-sized thumbnails via
/// `ContentResolver.loadThumbnail` (API 29+), and stream-copy file
/// resolution into the app cache so `dart:io` can read what the
/// system holds behind a `content://` URI.
class GalleryPlugin : NativePlugin, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener,
    EventChannel.StreamHandler {
    private var methodChannel: MethodChannel? = null
    private var changesChannel: EventChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    /// Active permission request — set when [handleRequestPermission]
    /// asks the user, cleared in [onRequestPermissionsResult]. Reentrancy
    /// is rejected.
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// In-flight `ACTION_PICK_IMAGES` Manage flow. Set by
    /// [handlePresentLimitedLibraryPicker], cleared by [onActivityResult].
    /// Reentrancy is rejected.
    private var pendingPickerResult: MethodChannel.Result? = null

    /// Dart subscriber on `ux/gallery/changes` — fed by [mediaObserver]
    /// when `MediaStore` reports an insert/update/delete so picker UIs
    /// can reload reactively (parity with iOS's `photoLibraryDidChange`).
    private var libraryEventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mediaObserver = object : ContentObserver(mainHandler) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            libraryEventSink?.success(null)
        }
    }
    private var mediaObserverRegistered = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/gallery").also {
            it.setMethodCallHandler(this)
        }
        changesChannel = EventChannel(
            binding.binaryMessenger, "ux/gallery/changes",
        ).also { it.setStreamHandler(this) }
        reconcilePersistedPickerUris()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        changesChannel?.setStreamHandler(null)
        changesChannel = null
        unregisterMediaObserver()
        context = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        libraryEventSink = events
        registerMediaObserver()
    }

    override fun onCancel(arguments: Any?) {
        libraryEventSink = null
        unregisterMediaObserver()
    }

    private fun registerMediaObserver() {
        if (mediaObserverRegistered) return
        val ctx = context ?: return
        ctx.contentResolver.registerContentObserver(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            /* notifyForDescendants */ true,
            mediaObserver,
        )
        mediaObserverRegistered = true
    }

    private fun unregisterMediaObserver() {
        if (!mediaObserverRegistered) return
        context?.contentResolver?.unregisterContentObserver(mediaObserver)
        mediaObserverRegistered = false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        pendingPermissionResult?.success("denied")
        pendingPermissionResult = null
        pendingPickerResult?.success(null)
        pendingPickerResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permission" -> handlePermission(result)
            "requestPermission" -> handleRequestPermission(result)
            "openSettings" -> handleOpenSettings(result)
            "presentLimitedLibraryPicker" -> handlePresentLimitedLibraryPicker(result)
            "albums" -> handleAlbums(call, result)
            "assets" -> handleAssets(call, result)
            "thumbnail" -> handleThumbnail(call, result)
            "resolveFile" -> handleResolveFile(call, result)
            else -> result.notImplemented()
        }
    }

    // ─── Permission ─────────────────────────────────────────────────────

    /// Permissions we need at runtime. API 33+ uses the per-media-type
    /// split (`READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO`) — and on API 34+
    /// `READ_MEDIA_VISUAL_USER_SELECTED` is the "limited" analogue of
    /// iOS's limited photo access. On older devices everything routes
    /// through the legacy `READ_EXTERNAL_STORAGE`.
    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
            )
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun isGranted(permission: String): Boolean {
        val ctx = context ?: return false
        return ContextCompat.checkSelfPermission(ctx, permission) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun handlePermission(result: MethodChannel.Result) {
        result.success(currentPermissionString())
    }

    private fun currentPermissionString(): String {
        // API 34+: USER_SELECTED grants partial access (telegram's
        // "limited" equivalent). We surface it as "limited" so the
        // picker can prompt the user with the system "manage" sheet.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val userSelected = isGranted(
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            val full = isGranted(Manifest.permission.READ_MEDIA_IMAGES) &&
                isGranted(Manifest.permission.READ_MEDIA_VIDEO)
            if (full) return "granted"
            if (userSelected) return "limited"
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val full = isGranted(Manifest.permission.READ_MEDIA_IMAGES) &&
                isGranted(Manifest.permission.READ_MEDIA_VIDEO)
            if (full) return "granted"
        } else {
            if (isGranted(Manifest.permission.READ_EXTERNAL_STORAGE)) {
                return "granted"
            }
        }
        // We can't tell apart "user denied permanently" from "never asked"
        // without using ActivityCompat.shouldShowRequestPermissionRationale,
        // which itself requires an Activity reference and only works after
        // a request. Default to "notDetermined" so the caller will try
        // requestPermission(); if denied permanently, the request resolves
        // immediately to "denied" and the UI routes to settings.
        return "notDetermined"
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error("no_activity", "plugin not attached to an activity", null)
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "in_progress", "a permission request is already in progress", null,
            )
            return
        }
        // If already granted, short-circuit — Android will pop the dialog
        // anyway if we call requestPermissions on a granted perm, which
        // is a worse UX than a no-op.
        val cur = currentPermissionString()
        if (cur == "granted" || cur == "limited") {
            result.success(cur)
            return
        }
        pendingPermissionResult = result
        act.requestPermissions(requiredPermissions(), REQUEST_CODE_PERMISSION)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE_PERMISSION) return false
        val r = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        r.success(currentPermissionString())
        return true
    }

    /// Android analogue of iOS's `PHPhotoLibrary.presentLimitedLibraryPicker`.
    /// Opens the system Photo Picker (`ACTION_PICK_IMAGES`, API 33+) for
    /// multi-select; returned URIs are persisted via
    /// `takePersistableUriPermission` in [onActivityResult] and merged
    /// with the `MediaStore.Images` / `Video` queries in [handleAssets].
    ///
    /// The legacy `requestPermissions(USER_SELECTED, …)` path falls back to
    /// the same Photo Picker UI on Android 14+ when `READ_MEDIA_IMAGES` /
    /// `VIDEO` are `USER_FIXED`, but its Done press doesn't write back to
    /// the `READ_MEDIA_VISUAL_USER_SELECTED` grant — only this explicit
    /// flow reliably grows the accessible subset.
    private fun handlePresentLimitedLibraryPicker(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(null)
            return
        }
        val act = activity ?: run {
            result.success(null)
            return
        }
        if (pendingPickerResult != null) {
            result.success(null)
            return
        }
        pendingPickerResult = result
        // Don't set `type` — default surfaces both images and video in
        // one sheet. Mixing "image/*"+"video/*" in the type string is
        // invalid; EXTRA_MIME_TYPES would be the workaround if we ever
        // need to filter by kind.
        val intent = Intent(MediaStore.ACTION_PICK_IMAGES).apply {
            putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 100)
        }
        try {
            act.startActivityForResult(intent, REQUEST_CODE_PICKER)
        } catch (_: Throwable) {
            pendingPickerResult = null
            result.success(null)
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQUEST_CODE_PICKER) return false
        val r = pendingPickerResult ?: return true
        pendingPickerResult = null
        val ctx = context
        if (resultCode == Activity.RESULT_OK && data != null && ctx != null) {
            val picked = extractUris(data)
            for (uri in picked) {
                try {
                    ctx.contentResolver.takePersistableUriPermission(
                        uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    // Picker URIs are always persistable, but stay defensive.
                }
            }
            if (picked.isNotEmpty()) {
                appendPickerUris(ctx, picked)
                libraryEventSink?.success(null)
            }
        }
        r.success(null)
        return true
    }

    private fun extractUris(data: Intent): List<Uri> {
        val out = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) out.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { out.add(it) }
        }
        return out
    }

    private fun handleOpenSettings(result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("no_context", "no application context", null)
            return
        }
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", ctx.packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        ctx.startActivity(intent)
        result.success(null)
    }

    // ─── Albums ─────────────────────────────────────────────────────────

    private fun handleAlbums(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("no_context", "no application context", null)
            return
        }
        val filter = (call.argument<String>("filter") ?: "any")
        val albums = mutableListOf<Map<String, Any?>>()

        // Recents — virtual album over the entire library.
        val recentsCount = countAssets(ctx, filter, bucketId = null)
        if (recentsCount > 0) {
            albums.add(
                mapOf(
                    "id" to "recents",
                    "name" to "Recents",
                    "count" to recentsCount,
                    "cover_kind" to firstAssetKind(ctx, filter, bucketId = null),
                ),
            )
        }

        // User buckets — DISTINCT bucket_id ordered by most-recent.
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.Files.FileColumns.BUCKET_ID,
            MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
        )
        val seenBuckets = LinkedHashMap<Long, String?>()
        val (selection, selectionArgs) = filterToSelection(filter)
        ctx.contentResolver.query(
            uri,
            projection,
            selection,
            selectionArgs,
            "${MediaStore.Files.FileColumns.DATE_ADDED} DESC",
        )?.use { c ->
            val bucketIdIdx = c.getColumnIndex(MediaStore.Files.FileColumns.BUCKET_ID)
            val bucketNameIdx = c.getColumnIndex(
                MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
            )
            while (c.moveToNext()) {
                if (bucketIdIdx < 0 || c.isNull(bucketIdIdx)) continue
                val id = c.getLong(bucketIdIdx)
                if (seenBuckets.containsKey(id)) continue
                val name = if (bucketNameIdx >= 0) c.getString(bucketNameIdx) else null
                seenBuckets[id] = name
            }
        }
        for ((id, name) in seenBuckets) {
            // Skip system / unnamed buckets — their photos remain
            // reachable via Recents, but an unlabeled row in the album
            // dropdown is dead-end UX.
            if (name.isNullOrBlank()) continue
            val count = countAssets(ctx, filter, bucketId = id)
            if (count == 0) continue
            albums.add(
                mapOf(
                    "id" to id.toString(),
                    "name" to name,
                    "count" to count,
                    "cover_kind" to firstAssetKind(ctx, filter, bucketId = id),
                ),
            )
        }

        result.success(albums)
    }

    private fun countAssets(ctx: Context, filter: String, bucketId: Long?): Int {
        val (selection, selectionArgs) = filterToSelection(filter, bucketId)
        return ctx.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(MediaStore.Files.FileColumns._ID),
            selection,
            selectionArgs,
            null,
        )?.use { it.count } ?: 0
    }

    private fun firstAssetKind(
        ctx: Context, filter: String, bucketId: Long?,
    ): String? {
        // API 30+ rejects `LIMIT` / `OFFSET` injected into the sort-order
        // string ("Invalid token LIMIT"). Just sort and take the first row.
        val (selection, selectionArgs) = filterToSelection(filter, bucketId)
        return ctx.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE),
            selection,
            selectionArgs,
            "${MediaStore.Files.FileColumns.DATE_ADDED} DESC",
        )?.use { c ->
            if (c.moveToFirst()) mediaTypeToKind(c.getInt(0)) else null
        }
    }

    // ─── Assets ─────────────────────────────────────────────────────────

    private fun handleAssets(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("no_context", "no application context", null)
            return
        }
        val albumId = call.argument<String>("albumId")
        val filter = call.argument<String>("filter") ?: "any"
        val start = (call.argument<Number>("start") ?: 0).toInt()
        val end = (call.argument<Number>("end") ?: 0).toInt()
        val limit = (end - start).coerceAtLeast(0)
        if (limit == 0) {
            result.success(emptyList<Any?>())
            return
        }

        val bucketId = albumId?.takeIf { it != "recents" }?.toLongOrNull()

        // Query per-type tables (Images / Video) rather than the unified
        // `MediaStore.Files` URI. The Files URI requires the legacy
        // `READ_EXTERNAL_STORAGE` for full visibility — under
        // `READ_MEDIA_VISUAL_USER_SELECTED` (Android 14+ limited mode)
        // it under-reports rows that the per-type URIs return in full.
        val merged = mutableListOf<Map<String, Any?>>()
        if (filter == "image" || filter == "any") {
            merged.addAll(queryMediaTable(
                ctx,
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                kind = "image",
                bucketId = bucketId,
                limit = end,
            ))
        }
        if (filter == "video" || filter == "any") {
            merged.addAll(queryMediaTable(
                ctx,
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                kind = "video",
                bucketId = bucketId,
                limit = end,
            ))
        }
        // Picker URIs persisted from [handlePresentLimitedLibraryPicker]
        // are an additional source: they have no MediaStore bucket so
        // they only contribute to Recents, never to per-bucket album views.
        if (bucketId == null) {
            merged.addAll(queryPersistedPickerUris(ctx, filter, end))
        }
        merged.sortByDescending { (it["created_ms"] as? Long) ?: 0L }
        result.success(merged.drop(start).take(limit))
    }

    private fun queryMediaTable(
        ctx: Context,
        tableUri: Uri,
        kind: String,
        bucketId: Long?,
        limit: Int,
    ): List<Map<String, Any?>> {
        val projection = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_TAKEN,
        )
        if (kind == "video") projection.add(MediaStore.Video.Media.DURATION)
        val sel = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (bucketId != null) {
            sel.add("${MediaStore.MediaColumns.BUCKET_ID} = ?")
            args.add(bucketId.toString())
        }
        val selection = sel.joinToString(" AND ").takeIf { it.isNotEmpty() }
        val out = mutableListOf<Map<String, Any?>>()
        ctx.contentResolver.query(
            tableUri,
            projection.toTypedArray(),
            selection,
            args.toTypedArray(),
            "${MediaStore.MediaColumns.DATE_ADDED} DESC",
        )?.use { c ->
            val idIdx = c.getColumnIndex(MediaStore.MediaColumns._ID)
            val widthIdx = c.getColumnIndex(MediaStore.MediaColumns.WIDTH)
            val heightIdx = c.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
            val takenIdx = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
            val addedIdx = c.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
            val durationIdx = c.getColumnIndex(MediaStore.Video.Media.DURATION)
            var taken = 0
            while (taken < limit && c.moveToNext()) {
                val id = c.getLong(idIdx)
                val width = if (widthIdx >= 0) c.getInt(widthIdx) else 0
                val height = if (heightIdx >= 0) c.getInt(heightIdx) else 0
                val durationMs = if (kind == "video" && durationIdx >= 0 &&
                    !c.isNull(durationIdx)) c.getLong(durationIdx) else null
                // DATE_TAKEN is in ms since epoch; DATE_ADDED is in
                // seconds. Prefer taken when set, fall back to added.
                val createdMs = when {
                    takenIdx >= 0 && !c.isNull(takenIdx) && c.getLong(takenIdx) > 0 ->
                        c.getLong(takenIdx)
                    addedIdx >= 0 && !c.isNull(addedIdx) ->
                        c.getLong(addedIdx) * 1000L
                    else -> 0L
                }
                out.add(
                    mapOf<String, Any?>(
                        "id" to ContentUris.withAppendedId(tableUri, id).toString(),
                        "kind" to kind,
                        "duration_ms" to durationMs,
                        "width" to width,
                        "height" to height,
                        "created_ms" to createdMs,
                    ),
                )
                taken++
            }
        }
        return out
    }

    // ─── Thumbnail ──────────────────────────────────────────────────────

    private fun handleThumbnail(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("no_context", "no application context", null)
            return
        }
        val assetId = call.argument<String>("assetId") ?: run {
            result.error("bad_args", "missing assetId", null)
            return
        }
        val sizePx = (call.argument<Number>("sizePx") ?: 0).toInt()
        if (sizePx <= 0) {
            result.error("bad_args", "sizePx must be > 0", null)
            return
        }

        val uri = parseAssetUri(assetId) ?: run {
            result.error("bad_args", "assetId is not a content URI", null)
            return
        }

        try {
            // ContentResolver.loadThumbnail (API 29+) is the right call —
            // backed by the system thumbnail cache, no need to roll our
            // own. For older devices, fall back to opening the original
            // and Bitmap-decoding (slower; expected to be rare).
            val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ctx.contentResolver.loadThumbnail(uri, Size(sizePx, sizePx), null)
            } else {
                ctx.contentResolver.openInputStream(uri)?.use { input ->
                    android.graphics.BitmapFactory.decodeStream(input)
                } ?: run {
                    result.error("decode_failed", "could not decode bitmap", null)
                    return
                }
            }

            val baos = ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, baos)
            result.success(
                mapOf<String, Any?>(
                    "bytes" to baos.toByteArray(),
                    "width" to bitmap.width,
                    "height" to bitmap.height,
                ),
            )
        } catch (e: Throwable) {
            result.error("thumbnail_failed", e.message, null)
        }
    }

    // ─── Resolve file ───────────────────────────────────────────────────

    private fun handleResolveFile(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("no_context", "no application context", null)
            return
        }
        val assetId = call.argument<String>("assetId") ?: run {
            result.error("bad_args", "missing assetId", null)
            return
        }
        val uri = parseAssetUri(assetId) ?: run {
            result.error("bad_args", "assetId is not a content URI", null)
            return
        }

        try {
            val (displayName, mime) = queryNameAndMime(ctx, uri)
            val safeName = (displayName ?: ContentUris.parseId(uri).toString())
                .replace(Regex("[\\\\/:*?\"<>|]"), "_")
            val ext = mime?.let { extensionForMime(it) }
                ?: safeName.substringAfterLast('.', "")
            val dir = File(ctx.cacheDir, "ux_gallery").apply { mkdirs() }
            val out = File(
                dir,
                if (ext.isNotEmpty() && !safeName.endsWith(".$ext")) {
                    "$safeName.$ext"
                } else {
                    safeName
                },
            )

            if (out.exists() && out.length() > 0) {
                result.success(out.absolutePath)
                return
            }

            ctx.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "openInputStream returned null for $uri" }
                FileOutputStream(out).use { output ->
                    val buf = ByteArray(16 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                    }
                }
            }

            result.success(out.absolutePath)
        } catch (e: Throwable) {
            result.error("resolve_failed", e.message, null)
        }
    }

    private fun queryNameAndMime(ctx: Context, uri: Uri): Pair<String?, String?> {
        var name: String? = null
        ctx.contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null, null, null,
        )?.use { c: Cursor ->
            if (c.moveToFirst() && c.columnCount > 0 && !c.isNull(0)) {
                name = c.getString(0)
            }
        }
        return name to ctx.contentResolver.getType(uri)
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    private fun filterToSelection(
        filter: String, bucketId: Long? = null,
    ): Pair<String, Array<String>> {
        val parts = mutableListOf<String>()
        val args = mutableListOf<String>()
        when (filter) {
            "image" -> {
                parts += "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
                args += MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString()
            }
            "video" -> {
                parts += "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
                args += MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
            }
            else -> {
                parts += "(${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR " +
                    "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?)"
                args += MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString()
                args += MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
            }
        }
        if (bucketId != null) {
            parts += "${MediaStore.Files.FileColumns.BUCKET_ID} = ?"
            args += bucketId.toString()
        }
        return parts.joinToString(" AND ") to args.toTypedArray()
    }

    private fun mediaTypeToKind(mediaType: Int): String? = when (mediaType) {
        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> "image"
        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> "video"
        else -> null
    }

    private fun parseAssetUri(s: String): Uri? = try {
        val uri = Uri.parse(s)
        if (uri.scheme == "content") uri else null
    } catch (_: Throwable) {
        null
    }

    private fun extensionForMime(mime: String): String = when (mime) {
        "image/jpeg" -> "jpg"
        "image/png" -> "png"
        "image/heic", "image/heif" -> "heic"
        "image/webp" -> "webp"
        "image/gif" -> "gif"
        "video/mp4" -> "mp4"
        "video/quicktime" -> "mov"
        "video/3gpp" -> "3gp"
        "video/webm" -> "webm"
        else -> mime.substringAfter('/', "bin")
    }

    // ─── Photo Picker URI persistence ───────────────────────────────────

    /// Reads the persisted picker-URI list in insertion order. Stored as
    /// a single newline-separated string under [PICKER_URIS_KEY] —
    /// `SharedPreferences.getStringSet` doesn't preserve order, which we
    /// need for the "drop oldest on overflow" eviction.
    private fun readPickerUris(ctx: Context): LinkedHashSet<String> {
        val raw = ctx
            .getSharedPreferences(PICKER_PREFS, Context.MODE_PRIVATE)
            .getString(PICKER_URIS_KEY, null) ?: return LinkedHashSet()
        return raw.split('\n')
            .filter { it.isNotEmpty() }
            .toCollection(LinkedHashSet())
    }

    private fun writePickerUris(ctx: Context, set: LinkedHashSet<String>) {
        ctx.getSharedPreferences(PICKER_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PICKER_URIS_KEY, set.joinToString("\n"))
            .commit()
    }

    /// Appends [new] URIs to the persisted set (union, ordered). On
    /// overflow past [PICKER_URI_CAP], drops from the head (oldest first)
    /// and releases the kernel-level URI grant for each evicted entry.
    private fun appendPickerUris(ctx: Context, new: List<Uri>) {
        val set = readPickerUris(ctx)
        for (uri in new) set.add(uri.toString())
        if (set.size > PICKER_URI_CAP) {
            val excess = set.size - PICKER_URI_CAP
            val iter = set.iterator()
            repeat(excess) {
                val dropped = iter.next()
                iter.remove()
                try {
                    ctx.contentResolver.releasePersistableUriPermission(
                        Uri.parse(dropped),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    // Grant may already be gone — best effort.
                }
            }
        }
        writePickerUris(ctx, set)
    }

    /// Resolves each persisted picker URI to a row in the same shape as
    /// [queryMediaTable]. URIs that the system has revoked (Settings,
    /// kernel-eviction, deleted source) are pruned from the persisted
    /// set inline.
    private fun queryPersistedPickerUris(
        ctx: Context,
        filter: String,
        limit: Int,
    ): List<Map<String, Any?>> {
        val set = readPickerUris(ctx)
        if (set.isEmpty()) return emptyList()
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DURATION,
        )
        val out = mutableListOf<Map<String, Any?>>()
        val dead = mutableListOf<String>()
        for (uriStr in set) {
            if (out.size >= limit) break
            val uri = try { Uri.parse(uriStr) } catch (_: Throwable) {
                dead.add(uriStr); continue
            }
            val row = try {
                ctx.contentResolver.query(uri, projection, null, null, null)
                    ?.use { c -> if (c.moveToFirst()) readRow(c, uri) else null }
            } catch (_: SecurityException) {
                null
            }
            if (row == null) {
                dead.add(uriStr)
                continue
            }
            val kind = row["kind"] as String
            val keep = when (filter) {
                "image" -> kind == "image"
                "video" -> kind == "video"
                else -> true
            }
            if (keep) out.add(row)
        }
        if (dead.isNotEmpty()) {
            set.removeAll(dead.toSet())
            writePickerUris(ctx, set)
            for (s in dead) {
                try {
                    ctx.contentResolver.releasePersistableUriPermission(
                        Uri.parse(s), Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: Throwable) { /* best effort */ }
            }
        }
        return out
    }

    private fun readRow(c: Cursor, uri: Uri): Map<String, Any?> {
        val widthIdx = c.getColumnIndex(MediaStore.MediaColumns.WIDTH)
        val heightIdx = c.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
        val takenIdx = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
        val addedIdx = c.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
        val mimeIdx = c.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)
        val durIdx = c.getColumnIndex(MediaStore.MediaColumns.DURATION)
        val mime = if (mimeIdx >= 0 && !c.isNull(mimeIdx)) c.getString(mimeIdx) else null
        val kind = if (mime?.startsWith("video/") == true) "video" else "image"
        val width = if (widthIdx >= 0 && !c.isNull(widthIdx)) c.getInt(widthIdx) else 0
        val height = if (heightIdx >= 0 && !c.isNull(heightIdx)) c.getInt(heightIdx) else 0
        val durationMs = if (kind == "video" && durIdx >= 0 && !c.isNull(durIdx)) {
            c.getLong(durIdx)
        } else null
        val createdMs = when {
            takenIdx >= 0 && !c.isNull(takenIdx) && c.getLong(takenIdx) > 0 ->
                c.getLong(takenIdx)
            addedIdx >= 0 && !c.isNull(addedIdx) ->
                c.getLong(addedIdx) * 1000L
            else -> 0L
        }
        return mapOf(
            "id" to uri.toString(),
            "kind" to kind,
            "duration_ms" to durationMs,
            "width" to width,
            "height" to height,
            "created_ms" to createdMs,
        )
    }

    /// Prune persisted URIs that the kernel no longer reports as granted
    /// — covers Settings-side revocation between app runs and the 512-
    /// URI kernel cap evicting our oldest grants.
    private fun reconcilePersistedPickerUris() {
        val ctx = context ?: return
        val persisted = readPickerUris(ctx)
        if (persisted.isEmpty()) return
        val live = ctx.contentResolver.persistedUriPermissions
            .map { it.uri.toString() }
            .toSet()
        val alive = persisted.filterTo(LinkedHashSet()) { it in live }
        if (alive.size != persisted.size) writePickerUris(ctx, alive)
    }

    companion object {
        private const val REQUEST_CODE_PERMISSION = 0xC52
        private const val REQUEST_CODE_PICKER = 0xC53
        private const val PICKER_PREFS = "ux_gallery_picker"
        private const val PICKER_URIS_KEY = "picker_uris"
        private const val PICKER_URI_CAP = 400
    }
}
