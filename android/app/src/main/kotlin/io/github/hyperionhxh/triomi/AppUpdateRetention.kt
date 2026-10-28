package io.github.hyperionhxh.triomi

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.UUID

/** Only direct, updater-created files are visited. Installer leases survive process death. */
class AppUpdateRetention(
    cacheParent: File,
    legacyParent: File,
    private val installed: () -> Identity,
    private val inspect: (File) -> Identity,
) {
    data class Identity(val packageName: String, val versionCode: Long, val signer: String)
    data class StorageInfo(
        val incomingBytes: Long = 0,
        val installBytes: Long = 0,
        val legacyBytes: Long = 0,
        val reclaimableBytes: Long = 0,
        val protectedBytes: Long = 0,
        val removedBytes: Long = 0,
        val skippedFiles: Int = 0,
    ) {
        fun asMap(): Map<String, Any> = mapOf(
            "incomingBytes" to incomingBytes, "installBytes" to installBytes,
            "legacyBytes" to legacyBytes, "reclaimableBytes" to reclaimableBytes,
            "protectedBytes" to protectedBytes, "removedBytes" to removedBytes,
            "skippedFiles" to skippedFiles,
        )
    }

    private val cacheParent = cacheParent.canonicalFile
    private val legacyParent = legacyParent.canonicalFile
    private val root = File(this.cacheParent, "app-update")
    private val legacyRoot = File(this.legacyParent, "app-update")
    private val incoming = File(root, "incoming")
    private val install = File(root, "install")
    // Cache eviction must never erase the only durable installer-read protection.
    private val lease = File(legacyRoot, "installer-lease")
    private val leaseWrite = File(legacyRoot, "installer-lease.new")
    private val activeIncoming = liveIncoming
    private val candidates = mutableSetOf<String>()
    // UUID paths created in this instance cannot belong to an older uncertain lease.
    private val freshCandidates = mutableSetOf<String>()
    private var handoff: String? = null
    private var leaseUncertain = false

    private var initialized = false

    @Synchronized private fun initialize() {
        if (initialized) return
        if (existsNoFollow(legacyRoot) && !safeDirectory(legacyRoot, legacyParent)) {
            leaseUncertain = true
            initialized = true
            return
        }
        if (regular(lease) && lease.length() in 1..128) {
            val name = lease.readText()
            if (APK.matches(name)) handoff = File(install, name).absolutePath
            else leaseUncertain = true
        } else if (existsNoFollow(lease)) leaseUncertain = true
        initialized = true
    }

    private fun prepareStaging() {
        prepare(root, cacheParent)
        prepare(incoming, root)
        prepare(install, root)
    }

    @Synchronized fun beginIncoming(): File {
        initialize()
        prepareStaging()
        validate(incoming, root)
        val file = File(incoming, "download-${UUID.randomUUID()}.apk")
        check(file.createNewFile()) { "无法创建更新下载暂存" }
        activeIncoming.add(file.absolutePath)
        return file
    }

    @Synchronized fun finishIncoming(path: String): Boolean {
        initialize()
        val file = owned(path, incoming, INCOMING)
        activeIncoming.remove(file.absolutePath)
        return !existsNoFollow(file) || file.delete()
    }

    @Synchronized fun newCandidate(): File {
        initialize()
        prepareStaging()
        validate(install, root)
        val file = File(install, "${UUID.randomUUID()}.apk")
        check(file.createNewFile()) { "无法创建更新安装暂存" }
        candidates.add(file.absolutePath)
        freshCandidates.add(file.absolutePath)
        return file
    }

    @Synchronized fun copyIncoming(path: String, copy: (File, File) -> Unit): File {
        val source = owned(path, incoming, INCOMING)
        require(regular(source)) { "更新下载不是普通文件" }
        val target = newCandidate()
        try {
            copy(source, target)
            check(finishIncoming(path)) { "无法清理重复的下载暂存" }
            return target
        } catch (error: Throwable) {
            releaseCandidate(target)
            throw error
        }
    }

    @Synchronized fun candidateForWrite(file: File) {
        val owned = owned(file.path, install, APK)
        require(owned.absolutePath in candidates && regular(owned)) { "更新安装暂存未持有活动租约" }
    }

    @Synchronized fun pendingCandidate(): File? {
        initialize()
        val file = handoff?.let(::File) ?: return null
        if (!regular(file)) return null
        candidate(file.path)
        val current = installed()
        val offered = inspect(file)
        if (offered.packageName != current.packageName || offered.signer != current.signer ||
            offered.versionCode <= current.versionCode) return null
        candidates.add(file.absolutePath)
        return file
    }

    @Synchronized fun candidate(path: String): File {
        val raw = File(path).absoluteFile
        val directory = when (raw.parentFile) {
            install.absoluteFile -> install
            File(legacyRoot, "install").absoluteFile -> File(legacyRoot, "install")
            else -> throw IllegalArgumentException("更新安装暂存路径无效")
        }
        val file = owned(path, directory, APK)
        require(regular(file) && file.length() in 1..AppUpdateHost.MAX_APK_BYTES) { "更新安装暂存无效" }
        return file
    }

    @Synchronized fun beginHandoff(file: File): Boolean {
        candidate(file.path)
        require(file.parentFile == install.absoluteFile) { "旧版暂存需重新选择后安装" }
        require(!leaseUncertain && (handoff == null || handoff == file.absolutePath)) {
            "系统安装器仍可能读取上一更新包，请完成或取消该安装后重试"
        }
        // Retry the same immutable URI after process death. Keep its existing
        // lease even if this attempt fails: a previous installer may be reading.
        if (handoff == file.absolutePath) return false
        // Persist before granting a URI: process death cannot expose an unleased APK.
        prepare(legacyRoot, legacyParent)
        require(!existsNoFollow(lease) || regular(lease)) { "安装器交接记录无效" }
        require(!existsNoFollow(leaseWrite) || regular(leaseWrite)) { "安装器交接记录无效" }
        leaseWrite.outputStream().use { output ->
            output.write(file.name.toByteArray(Charsets.UTF_8))
            output.flush()
            output.fd.sync()
        }
        check(leaseWrite.renameTo(lease)) { "无法保存安装器交接记录" }
        handoff = file.absolutePath
        return true
    }

    @Synchronized fun finishHandoff(): File? {
        initialize()
        if (existsNoFollow(legacyRoot)) require(safeDirectory(legacyRoot, legacyParent)) { "安装器交接目录无效" }
        val file = handoff?.let(::File)
        if (file != null && existsNoFollow(file)) candidate(file.path)
        if (existsNoFollow(lease)) check(regular(lease) && lease.delete()) { "无法结束安装器交接记录" }
        handoff = null
        leaseUncertain = false
        // A visible candidate remains available for an explicit retry after install cancellation.
        if (file != null && regular(file)) {
            val current = installed()
            val offered = runCatching { inspect(file) }.getOrNull()
            val completed = offered != null && offered.packageName == current.packageName &&
                offered.signer == current.signer && offered.versionCode <= current.versionCode
            if (completed) candidates.remove(file.absolutePath)
            if (file.absolutePath !in candidates) check(file.delete()) { "无法清理已结束的安装暂存" }
        }
        return file
    }

    @Synchronized fun releaseCandidate(file: File, relinquish: Boolean = false): Boolean {
        val owned = ownedInstallAllowMissing(file.path)
        // Page disposal relinquishes ownership, but must not delete installer readers.
        if (relinquish) candidates.remove(owned.absolutePath)
        if (owned.absolutePath == handoff ||
            (leaseUncertain && owned.absolutePath !in freshCandidates)) return false
        val removed = !existsNoFollow(owned) || owned.delete()
        if (removed) {
            candidates.remove(owned.absolutePath)
            freshCandidates.remove(owned.absolutePath)
        }
        return removed
    }

    @Synchronized fun storageInfo(): StorageInfo = scan(mutate = false, clear = false)
    @Synchronized fun maintain(clear: Boolean = false): StorageInfo = scan(mutate = true, clear = clear)

    private fun scan(mutate: Boolean, clear: Boolean): StorageInfo {
        initialize()
        // One installed-package read per sweep; full APK parsing remains on the host executor.
        val current = installed()
        var incomingBytes = 0L
        var installBytes = 0L
        var legacyBytes = 0L
        var reclaimable = 0L
        var protected = 0L
        var removed = 0L
        var skipped = 0
        for ((base, legacy) in listOf(root to false, legacyRoot to true)) {
            if (!existsNoFollow(base)) continue
            if (!safeDirectory(base, if (legacy) legacyParent else cacheParent)) { skipped++; continue }
            for ((name, pattern) in listOf("incoming" to INCOMING, "install" to APK)) {
                val directory = File(base, name)
                if (!existsNoFollow(directory)) continue
                if (!safeDirectory(directory, base)) { skipped++; continue }
                for (file in directory.listFiles().orEmpty()) {
                    if (!pattern.matches(file.name) || !regular(file) || file.canonicalFile.parentFile != directory.canonicalFile) {
                        skipped++
                        continue
                    }
                    val bytes = file.length()
                    val path = file.absolutePath
                    val active = path in activeIncoming || path in candidates
                    var pending = path == handoff ||
                        (leaseUncertain && !legacy && name == "install" && path !in freshCandidates)
                    var installedOrObsolete = false
                    // Active download/copy/verification files are never parsed or deleted.
                    if (!active && name == "install") {
                        val identity = runCatching { inspect(file) }.getOrNull()
                        installedOrObsolete = identity != null && identity.packageName == current.packageName &&
                            identity.signer == current.signer && identity.versionCode <= current.versionCode
                        if (legacy && identity != null && identity.packageName == current.packageName &&
                            identity.signer == current.signer && identity.versionCode > current.versionCode) pending = true
                    }
                    val safe = !active && (installedOrObsolete || !pending)
                    // Cache candidates without a surviving lease are abandoned after process death.
                    // Legacy newer APKs predate leases and remain protected until installed.
                    val automatic = safe && (installedOrObsolete || name == "incoming" || !legacy)
                    if (mutate && (automatic || (clear && safe)) && file.delete()) {
                        removed += bytes
                        if (path == handoff) {
                            handoff = null
                            if (regular(lease)) lease.delete()
                        }
                        continue
                    }
                    if (legacy) legacyBytes += bytes
                    else if (name == "incoming") incomingBytes += bytes
                    else installBytes += bytes
                    if (safe) reclaimable += bytes else protected += bytes
                }
            }
        }
        if (mutate && handoff != null && !existsNoFollow(File(handoff!!))) {
            handoff = null
            if (regular(lease)) lease.delete()
        }
        return StorageInfo(incomingBytes, installBytes, legacyBytes, reclaimable, protected, removed, skipped)
    }

    @Synchronized fun close(incomingPath: String? = null) {
        if (incomingPath != null) runCatching { finishIncoming(incomingPath) }
        for (path in candidates.toList()) runCatching { releaseCandidate(File(path)) }
        // Disposal relinquishes page ownership, unlike a rejected explicit discard.
        candidates.clear()
    }

    private fun ownedInstallAllowMissing(path: String): File {
        val raw = File(path).absoluteFile
        val directory = if (raw.parentFile == install.absoluteFile) install else File(legacyRoot, "install")
        return owned(path, directory, APK)
    }

    private fun owned(path: String, directory: File, pattern: Regex): File {
        val raw = File(path).absoluteFile
        val base = if (directory.parentFile == root) root else legacyRoot
        validate(directory, base)
        require(raw.parentFile == directory.absoluteFile && pattern.matches(raw.name) && raw.canonicalFile == raw &&
            (!existsNoFollow(raw) || regular(raw))) { "更新暂存路径别名或非普通文件被拒绝" }
        return raw
    }

    private fun validate(directory: File, parent: File) {
        val expectedParent = if (parent == root) cacheParent else legacyParent
        require(safeDirectory(parent, expectedParent) && safeDirectory(directory, parent)) { "更新暂存目录路径别名被拒绝" }
    }

    private fun prepare(directory: File, parent: File) {
        if (!existsNoFollow(directory)) check(directory.mkdir()) { "无法创建更新暂存目录" }
        require(safeDirectory(directory, parent)) { "更新暂存目录路径别名被拒绝" }
    }

    private fun safeDirectory(directory: File, parent: File): Boolean = runCatching {
        val mode = Os.lstat(directory.path).st_mode
        OsConstants.S_ISDIR(mode) && !OsConstants.S_ISLNK(mode) &&
            directory.canonicalFile == directory.absoluteFile && directory.canonicalFile.parentFile == parent.canonicalFile
    }.getOrDefault(false)
    private fun regular(file: File): Boolean = runCatching { OsConstants.S_ISREG(Os.lstat(file.path).st_mode) }.getOrDefault(false)
    private fun existsNoFollow(file: File): Boolean = runCatching { Os.lstat(file.path); true }.getOrDefault(false)

    companion object {
        private val liveIncoming = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        private val UUID_NAME = "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"
        private val APK = Regex("^$UUID_NAME\\.apk$")
        private val INCOMING = Regex("^download-(?:[0-9]{1,20}|$UUID_NAME)\\.apk$")
    }
}
