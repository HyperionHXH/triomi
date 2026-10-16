package io.github.hyperionhxh.triomi

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

/** Uses the existing plugin's Keystore, preferences and exact logical prefix,
 * but commits the protected PIN synchronously before acknowledging success. */
object SecureStorePersistence {
    private const val RECORD = "privacyLock.record.v1"
    private const val PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "triomi/secure-store-durable").setMethodCallHandler { call, result ->
            val key = call.argument<String>("key")
            if (key != RECORD || call.method !in setOf("read", "write", "remove")) {
                result.error("invalid_record", "unsupported protected record", null)
                return@setMethodCallHandler
            }
            val value = call.argument<String>("value")
            executor.execute {
                try {
                    val master = MasterKey.Builder(app).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                    val prefs = EncryptedSharedPreferences.create(app, "FlutterSecureStorage", master,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
                    val storedKey = PREFIX + key
                    val response: String? = when (call.method) {
                        "read" -> prefs.getString(storedKey, null)
                        "write" -> {
                            require(value != null && value.length <= 4096)
                            check(prefs.edit().putString(storedKey, value).commit()) { "protected commit failed" }
                            check(prefs.getString(storedKey, null) == value) { "protected readback failed" }
                            value
                        }
                        else -> {
                            check(prefs.edit().remove(storedKey).commit()) { "protected removal failed" }
                            check(!prefs.contains(storedKey)) { "protected removal readback failed" }
                            null
                        }
                    }
                    main.post { result.success(response) }
                } catch (_: Exception) {
                    main.post { result.error("protected_storage_unavailable", "protected storage could not be persisted", null) }
                }
            }
        }
    }
}
