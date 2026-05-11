package io.swipelab.ux

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

class CrashPlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/crash").also {
            it.setMethodCallHandler(this)
        }
        installHandlerOnce(ctx)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "drainPending" -> handleDrain(result)
            "ackCrash" -> handleAck(call, result)
            "triggerTestCrash" -> handleTriggerTestCrash(result)
            else -> result.notImplemented()
        }
    }

    private fun handleTriggerTestCrash(result: MethodChannel.Result) {
        result.success(null)
        Thread({ throw RuntimeException("ux/crash triggerTestCrash") }, "ux-crash-test").start()
    }

    private fun handleDrain(result: MethodChannel.Result) {
        val dir = crashDir
        if (dir == null || !dir.isDirectory) return result.success(emptyList<Map<String, Any?>>())
        val files = dir.listFiles { _, name -> name.endsWith(".json") }?.toList().orEmpty()
            .sortedBy { it.lastModified() }
        val out = ArrayList<Map<String, Any?>>(files.size)
        for (f in files) {
            val entry = try {
                val json = JSONObject(f.readText(Charsets.UTF_8))
                jsonToMap(json).toMutableMap().apply { put("id", f.nameWithoutExtension) }
            } catch (_: Exception) {
                f.delete()
                continue
            }
            out.add(entry)
        }
        result.success(out)
    }

    private fun handleAck(call: MethodCall, result: MethodChannel.Result) {
        val id = call.arguments as? String
            ?: return result.error("bad_args", "expected String id", null)
        crashDir?.let { File(it, "$id.json").delete() }
        result.success(null)
    }

    companion object {
        private var installed = false
        private var priorHandler: Thread.UncaughtExceptionHandler? = null
        private var crashDir: File? = null

        private fun installHandlerOnce(ctx: Context) {
            if (installed) return
            installed = true
            crashDir = File(ctx.cacheDir, "ux_crashes").apply { mkdirs() }
            priorHandler = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler(::uxCrashHandler)
        }

        private fun uxCrashHandler(thread: Thread, throwable: Throwable) {
            val dir = crashDir
            if (dir != null) {
                runCatching {
                    val jsons = dir.listFiles { _, name -> name.endsWith(".json") }?.toList().orEmpty()
                    if (jsons.size >= 50) {
                        jsons.sortedBy { it.lastModified() }
                            .take(jsons.size - 49)
                            .forEach { it.delete() }
                    }

                    val sw = StringWriter()
                    throwable.printStackTrace(PrintWriter(sw))
                    val payload = JSONObject().apply {
                        put("platform", "android")
                        put("time", iso8601(Date()))
                        put("thread", thread.name)
                        put("type", throwable.javaClass.name)
                        put("message", throwable.message ?: "")
                        put("stack", sw.toString())
                        put("cause", throwable.cause?.toString() ?: "")
                        put("sdkInt", Build.VERSION.SDK_INT)
                        put("packageName", dir.parentFile?.parentFile?.name ?: "")
                    }
                    val tmp = File(dir, "${UUID.randomUUID()}.json.tmp")
                    tmp.writeText(payload.toString(), Charsets.UTF_8)
                    tmp.renameTo(File(dir, tmp.name.removeSuffix(".tmp")))
                }
            }
            // Hand off to the prior handler so the platform's default crash
            // behavior (process kill, ANR dialog, etc.) still runs.
            priorHandler?.uncaughtException(thread, throwable)
        }

        private fun iso8601(d: Date): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            return fmt.format(d)
        }

        private fun jsonToMap(o: JSONObject): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>(o.length())
            val it = o.keys()
            while (it.hasNext()) {
                val k = it.next()
                out[k] = jsonValue(o.opt(k))
            }
            return out
        }

        private fun jsonValue(v: Any?): Any? = when (v) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonToMap(v)
            is JSONArray -> {
                val list = ArrayList<Any?>(v.length())
                for (i in 0 until v.length()) list.add(jsonValue(v.opt(i)))
                list
            }
            else -> v
        }
    }
}
