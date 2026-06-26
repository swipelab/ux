package io.swipelab.ux

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/// Native AES-256-CTR for chat-attachment upload encryption. Mirrors, byte for
/// byte, the app's pure-Dart `encryptChunk`: encrypts a slice as if a single
/// continuous CTR stream whose initial counter block is `iv` had already
/// processed `pos` plaintext bytes (CTR is symmetric, so the same call also
/// decrypts).
///
/// Hardware-accelerated: `Cipher.getInstance("AES/CTR/NoPadding")` resolves to
/// Conscrypt/BoringSSL (AndroidOpenSSL), which uses the ARMv8 AES instructions
/// on the Kirin 970 and similar. We deliberately do NOT pin a provider — some
/// OEM ROMs (EMUI) rename/reorder security providers, and a hardcoded provider
/// name would throw `NoSuchProviderException` only on those devices, only in
/// release. The provider that served the first cipher is logged once so a
/// silent pure-Java fallback is visible in logcat.
class CryptoPlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null

    // Each call builds its own Cipher (stateless), so concurrent encrypts on
    // the pool are safe and use multiple cores. Bounded so simultaneous uploads
    // can't spawn unbounded threads; daemon so it never blocks process exit.
    private val worker: ExecutorService = Executors.newFixedThreadPool(
        Runtime.getRuntime().availableProcessors().coerceIn(1, 4),
    ) { r -> Thread(r, "ux-crypto").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var providerLogged = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/crypto").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "aesCtrRange" -> handleRange(call, result)
            "aesCtrBytes" -> handleBytes(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleRange(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        // pos/size marshalled as 64-bit — a Dart int > 2^31 decodes as Long,
        // so read as Number and widen (reading as Int would CCE past 2 GB).
        val pos = call.argument<Number>("pos")?.toLong()
        val size = call.argument<Number>("size")?.toLong()
        val key = call.argument<ByteArray>("key")
        val iv = call.argument<ByteArray>("iv")
        if (path == null || pos == null || size == null || key == null || iv == null) {
            return result.error("bad_args", "path/pos/size/key/iv required", null)
        }
        if (key.size != 32 || iv.size != 16) {
            return result.error("bad_args", "key must be 32 bytes, iv 16", null)
        }
        worker.execute {
            try {
                val plain = readRange(path, pos, size)
                reply(result, encrypt(key, iv, pos, plain))
            } catch (e: Throwable) {
                replyError(result, e)
            }
        }
    }

    private fun handleBytes(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<ByteArray>("data")
        val pos = call.argument<Number>("pos")?.toLong()
        val key = call.argument<ByteArray>("key")
        val iv = call.argument<ByteArray>("iv")
        if (data == null || pos == null || key == null || iv == null) {
            return result.error("bad_args", "data/pos/key/iv required", null)
        }
        if (key.size != 32 || iv.size != 16) {
            return result.error("bad_args", "key must be 32 bytes, iv 16", null)
        }
        worker.execute {
            try {
                reply(result, encrypt(key, iv, pos, data))
            } catch (e: Throwable) {
                replyError(result, e)
            }
        }
    }

    /// Reads `size` bytes from `path` starting at `pos` into one buffer. The
    /// part size is bounded by the BE's partitioning (tens of MB at most).
    private fun readRange(path: String, pos: Long, size: Long): ByteArray {
        val n = size.toInt()
        val buf = ByteArray(n)
        RandomAccessFile(path, "r").use { raf ->
            raf.seek(pos)
            var off = 0
            while (off < n) {
                val r = raf.read(buf, off, n - off)
                if (r < 0) break
                off += r
            }
            if (off != n) throw IllegalStateException("short read: $off of $n at $pos")
        }
        return buf
    }

    /// AES-256-CTR over `plain`, aligned to byte `pos` of a continuous stream
    /// from offset 0. The counter is seeded to block `pos>>4`; the `pos&15`
    /// sub-block offset is handled by prepending that many zero bytes to the
    /// plaintext in a single one-shot encrypt and dropping them. One-shot (no
    /// cross-call cipher state) means a provider that buffers partial blocks
    /// can't desync the keystream — the offset trick is correct on any provider.
    private fun encrypt(key: ByteArray, iv: ByteArray, pos: Long, plain: ByteArray): ByteArray {
        val counter = counterFor(iv, pos shr 4)
        val byteOffset = (pos and 15L).toInt()
        val cipher = Cipher.getInstance("AES/CTR/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(counter))
        if (!providerLogged) {
            providerLogged = true
            Log.i("UxCrypto", "AES/CTR provider=${cipher.provider?.name}")
        }
        val input = ByteArray(byteOffset + plain.size)
        System.arraycopy(plain, 0, input, byteOffset, plain.size)
        val out = cipher.doFinal(input)
        return if (byteOffset == 0) out else out.copyOfRange(byteOffset, out.size)
    }

    /// `iv` (a 16-byte big-endian counter block) + `blocks`, carrying across all
    /// 16 bytes. Mirrors `incCounter` in the Dart reference exactly.
    private fun counterFor(iv: ByteArray, blocks: Long): ByteArray {
        val c = iv.copyOf()
        var n = blocks
        var i = c.size - 1
        while (i >= 0 && n > 0) {
            n += (c[i].toLong() and 0xff)
            c[i] = (n and 0xff).toByte()
            n = n shr 8
            i--
        }
        return c
    }

    // MethodChannel.Result must be settled on the platform main thread.
    private fun reply(result: MethodChannel.Result, bytes: ByteArray) =
        main.post { result.success(bytes) }

    private fun replyError(result: MethodChannel.Result, e: Throwable) =
        main.post { result.error("aes_failed", e.message ?: e.toString(), null) }
}
