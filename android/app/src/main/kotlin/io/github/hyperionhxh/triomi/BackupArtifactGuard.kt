package io.github.hyperionhxh.triomi

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.UUID

/** One registry for ALL Flutter engines in this JVM, backed by one OS lock.
 * FileLock alone is not a same-process/thread mutex. Never open/close a second
 * lock channel while this registry owns a POSIX lock. Process death releases
 * the OS lock; no stale PID or timestamp is treated as proof of death.
 */
object BackupArtifactGuard {
    private val leases = mutableSetOf<String>()
    private var cleanupOwner: String? = null
    private var file: RandomAccessFile? = null
    private var lock: FileLock? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "triomi/backup-artifacts").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> result.success(acquire(app, call.argument<Boolean>("cleanup") == true))
                "release" -> {
                    release(call.arguments as? String)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Synchronized
    fun acquire(context: Context, cleanup: Boolean = false): String? {
        if (cleanupOwner != null || (cleanup && leases.isNotEmpty())) return null
        if (leases.isEmpty()) {
            var opened: RandomAccessFile? = null
            try {
                val parent = context.filesDir.canonicalFile
                if (!parent.isDirectory) return null
                val root = File(parent, "backup-control")
                if (!root.exists() && !root.mkdir()) return null
                if (!root.isDirectory || root.absoluteFile != root.canonicalFile) return null
                val target = File(root, "artifacts.lock")
                if (target.exists() && (!target.isFile || target.absoluteFile != target.canonicalFile)) return null
                opened = RandomAccessFile(target, "rw")
                if (!target.isFile || target.absoluteFile != target.canonicalFile) {
                    opened.close()
                    return null
                }
                val acquired = opened.channel.tryLock(0L, 1L, false)
                if (acquired == null) {
                    opened.close()
                    return null
                }
                file = opened
                lock = acquired
            } catch (_: Exception) {
                try { opened?.close() } catch (_: Exception) { }
                return null
            }
        }
        val token = UUID.randomUUID().toString()
        leases.add(token)
        if (cleanup) cleanupOwner = token
        return token
    }

    @Synchronized
    fun release(token: String?) {
        if (token == null || !leases.remove(token)) return
        if (cleanupOwner == token) cleanupOwner = null
        if (leases.isEmpty()) {
            try { lock?.release() } catch (_: Exception) { }
            try { file?.close() } catch (_: Exception) { }
            lock = null
            file = null
        }
    }
}
