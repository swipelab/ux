package io.swipelab.ux

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// `ux/secure_store`. Values are sealed with an AES-256-GCM key that lives in
/// the AndroidKeyStore — the key material never enters the process, and on a
/// device with a TEE or StrongBox never leaves that hardware. The sealed bytes
/// (IV ++ ciphertext, base64) sit in a private SharedPreferences file, keyed
/// by the caller's key: values are unreadable off the device that wrote them,
/// key names are not secret.
///
/// API 22 and below answers `unsupported` because Keystore AES requires API 23.
///
/// Failures report the exception type. No key, value, or ciphertext is logged.
class SecureStorePlugin : NativePlugin, MethodChannel.MethodCallHandler {
    private companion object {
        const val KEY_ALIAS = "io.swipelab.ux.secure_store"
        const val PREFS = "io.swipelab.ux.secure_store"
        const val KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val KEY_BITS = 256
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }

    private var methodChannel: MethodChannel? = null
    private var prefs: SharedPreferences? = null

    /// One thread: Keystore round-trips stay off the platform thread, and the
    /// order Dart issues commands in is the order they hit the store.
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ux-secure-store").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        prefs = binding.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        methodChannel = MethodChannel(binding.binaryMessenger, "ux/secure_store").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        prefs = null
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key.isNullOrEmpty()) return result.error("bad_args", "key required", null)
        val store = prefs ?: return result.error("store_failed", "detached", null)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return result.error("unsupported", "Keystore AES requires API 23", null)
        }
        when (call.method) {
            "read" -> run(result) { read(store, key) }
            "write" -> {
                val value = call.argument<String>("value")
                    ?: return result.error("bad_args", "value required", null)
                run(result) { write(store, key, value); null }
            }
            "delete" -> run(result) { store.edit().remove(key).apply(); null }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, work: () -> String?) {
        try {
            worker.execute {
                try {
                    val value = work()
                    main.post { result.success(value) }
                } catch (e: Throwable) {
                    main.post { result.error("store_failed", e.javaClass.simpleName, null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("store_failed", "detached", null)
        }
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun read(store: SharedPreferences, key: String): String? {
        val sealed = store.getString(key, null) ?: return null
        val bytes = Base64.decode(sealed, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES),
        )
        return String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun write(store: SharedPreferences, key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        check(iv.size == IV_BYTES) { "GCM IV is ${iv.size} bytes" }
        val sealed = iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        store.edit().putString(key, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun secretKey(): SecretKey {
        val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val entry = keystore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (entry != null) return entry.secretKey

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(KEY_BITS)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }
}
