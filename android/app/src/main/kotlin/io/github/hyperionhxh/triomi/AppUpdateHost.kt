package io.github.hyperionhxh.triomi

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import androidx.core.content.FileProvider
import com.android.apksig.ApkVerifier
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Static APK verification only. Never loads candidate classes or silently installs. */
class AppUpdateHost(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "triomi/app-update")
    private val executor = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private var busy = false
    private var picker: MethodChannel.Result? = null
    @Volatile private var input: InputStream? = null
    private var handedOff: String? = null
    @Volatile private var activeStaged: File? = null
    private var lastProgress = 0L
    private val root = File(activity.filesDir, "app-update")
    private val installRoot = File(root, "install")
    private val incomingRoot = File(root, "incoming")

    init {
        installRoot.mkdirs()
        incomingRoot.mkdirs()
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancel" -> {
                cancelled.set(true)
                runCatching { input?.close() }
                // A system SAF picker stays under the user's control; no permission grants.
                result.success(true)
            }
            "current" -> work(result) { current() }
            "stagingDirectory" -> {
                try { validateDirectory(incomingRoot); result.success(incomingRoot.canonicalPath) }
                catch (_: Exception) { result.error("invalid_stage", "更新暂存目录无效", null) }
            }
            "pickApk" -> {
                if (busy) result.error("busy", "已有更新操作正在进行", null)
                else {
                    busy = true
                    cancelled.set(false)
                    picker = result
                    try {
                        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/vnd.android.package-archive", "application/octet-stream"))
                        }, REQUEST_PICK_APK)
                    } catch (_: Exception) {
                        busy = false
                        picker = null
                        result.error("picker_failed", "无法打开系统 APK 选择器", null)
                    }
                }
            }
            "inspect" -> work(result) {
                val original = ownedIncoming(requireNotNull(call.argument<String>("path")))
                val expected = call.argument<String>("sha256")
                require(expected == null || HASH.matches(expected)) { "预期 SHA-256 必须是完整 64 位小写散列" }
                val staged = copy(original.inputStream(), original.length())
                try { inspect(staged, call.argument<String>("source") ?: "用户选择的本地文件", expected) }
                catch (error: Throwable) { staged.delete(); throw error }
            }
            "discard" -> {
                try {
                    val file = ownedInstall(requireNotNull(call.argument<String>("path")))
                    result.success(file.canonicalPath == handedOff || file.delete())
                } catch (_: Exception) { result.success(false) }
            }
            "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls())
            "openUnknownSources" -> {
                try {
                    require(Build.VERSION.SDK_INT >= 26)
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                    result.success(true)
                } catch (_: Exception) { result.error("settings_failed", "无法打开此应用的未知来源安装设置；未授予权限", null) }
            }
            "launchInstaller" -> {
                val generation = activity.updateConsentGeneration()
                if (!activity.updateConsentCurrent(generation)) {
                    result.error("consent_expired", "请回到已解锁前台重新确认更新", null)
                    return
                }
                work(result, after = { metadata ->
                    require(metadata["decision"] == "upgrade") { "只允许已核验的新版本进入安装器" }
                    require(Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()) { "请先在系统设置中自行允许此应用安装，再重新确认" }
                    val file = ownedInstall(metadata["path"] as String)
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.app-update", file)
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        clipData = ClipData.newRawUri("Triomi verified update", uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    require(activity.updateConsentCurrent(generation)) { "安装确认已因失焦或重新锁定过期；请解锁后重新确认" }
                    activity.startActivity(intent)
                    handedOff = file.canonicalPath
                    mapOf("launched" to true)
                }) {
                    require(call.argument<Boolean>("consent") == true) { "必须明确确认系统安装器交接" }
                    val file = ownedInstall(requireNotNull(call.argument<String>("path")))
                    val expected = requireNotNull(call.argument<String>("sha256"))
                    require(HASH.matches(expected)) { "无效的确认散列" }
                    inspect(file, "已确认的暂存 APK", expected)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_APK) return false
        val result = picker ?: return true
        picker = null
        busy = false
        if (resultCode != Activity.RESULT_OK || data?.data == null || cancelled.get()) {
            result.success(null)
            return true
        }
        val uri = data.data!!
        work(result) {
            require(uri.scheme == "content") { "仅接受系统文档提供者的内容 URI" }
            var size: Long? = null
            var name = "本地 APK"
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0) name = cursor.getString(n).orEmpty().take(256)
                    if (s >= 0 && !cursor.isNull(s)) size = cursor.getLong(s)
                }
            }
            require(size == null || size!! in 1..MAX_APK_BYTES) { "APK 为空或超过 512 MiB" }
            val stream = requireNotNull(activity.contentResolver.openInputStream(uri)) { "无法读取所选 APK" }
            val staged = copy(stream, size)
            try { inspect(staged, "用户通过系统文件选择器选择：$name", null) }
            catch (error: Throwable) { staged.delete(); throw error }
        }
        return true
    }

    private fun work(result: MethodChannel.Result, after: ((Map<String, Any?>) -> Map<String, Any?>)? = null, block: () -> Map<String, Any?>) {
        if (busy) { result.error("busy", "已有更新操作正在进行", null); return }
        busy = true
        cancelled.set(false)
        executor.execute {
            try {
                val value = block()
                checkCancelled()
                activity.runOnUiThread {
                    try {
                        checkCancelled()
                        result.success(after?.invoke(value) ?: value)
                        activeStaged = null
                    }
                    catch (_: Cancelled) { cleanupCancelled(); result.error("cancelled", "操作已取消；未启动安装器", null) }
                    catch (error: Exception) { result.error("update_rejected", error.message ?: "更新交接失败", null) }
                    finally { busy = false }
                }
            } catch (_: Cancelled) {
                cleanupCancelled()
                activity.runOnUiThread { busy = false; result.error("cancelled", "操作已取消；未启动安装器", null) }
            } catch (_: Exception) {
                cleanupCancelled()
                activity.runOnUiThread { busy = false; result.error("update_invalid", "无法读取或核验 APK；安装器未启动", null) }
            }
        }
    }

    private fun current(): Map<String, Any?> {
        val info = activity.packageManager.getPackageInfo(activity.packageName, signingFlags())
        val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else @Suppress("DEPRECATION") info.signatures
        require(signers?.size == 1) { "当前应用必须只有一个实际安装签名" }
        val signer = digest(signers!!.single().toByteArray())
        return mapOf(
            "packageName" to info.packageName, "versionCode" to version(info),
            "version" to (info.versionName ?: ""), "signerSha256" to signer,
            "sha256" to fileHash(File(requireNotNull(info.applicationInfo).sourceDir)),
            "productionSigner" to (signer == PRODUCTION_SIGNER), "platform" to "android",
        )
    }

    private fun inspect(file: File, source: String, expected: String?): Map<String, Any?> {
        checkCancelled()
        val hash = fileHash(file)
        require(expected == null || hash == expected) { "APK SHA-256 与清单或确认内容不符" }
        progress("signature", file.length(), file.length())
        val signer = verifiedSigner(file, Build.VERSION.SDK_INT)
        checkCancelled()
        val info = requireNotNull(activity.packageManager.getPackageArchiveInfo(file.path, 0)) { "无法读取 APK 包名与版本" }
        val installed = current()
        val code = version(info)
        val decision = updateDecision(installed["packageName"] as String, installed["versionCode"] as Long,
            installed["signerSha256"] as String, installed["sha256"] as String,
            info.packageName, code, signer, hash, true)
        return mapOf(
            "packageName" to info.packageName, "versionCode" to code, "version" to (info.versionName ?: ""),
            "sha256" to hash, "signerSha256" to signer, "signatureVerified" to true,
            "source" to source, "path" to file.canonicalPath, "bytes" to file.length(),
            "decision" to decision, "current" to installed,
        )
    }

    private fun copy(stream: InputStream, expectedSize: Long?): File {
        val target = File(installRoot, "${UUID.randomUUID()}.apk")
        activeStaged = target
        var size = 0L
        input = stream
        try {
            validateDirectory(installRoot)
            stream.use { source -> target.outputStream().use { out ->
                val buffer = ByteArray(128 * 1024)
                while (true) {
                    checkCancelled()
                    val count = source.read(buffer)
                    if (count < 0) break
                    size += count
                    require(size <= MAX_APK_BYTES) { "APK 超过 512 MiB" }
                    out.write(buffer, 0, count)
                    progress("copy", size, expectedSize)
                }
                out.flush()
                out.fd.sync()
            } }
            checkCancelled()
            require(size > 0 && (expectedSize == null || size == expectedSize)) { "APK 为空或读取被截断" }
            require(target.setWritable(false, false)) { "无法保护暂存 APK" }
            target.setExecutable(false, false)
            return target
        } catch (error: Throwable) { target.delete(); if (cancelled.get()) throw Cancelled(); throw error }
        finally { input = null }
    }

    private fun ownedIncoming(path: String): File = ownedFile(path, incomingRoot)
    private fun ownedInstall(path: String): File = ownedFile(path, installRoot)
    private fun ownedFile(path: String, directory: File): File {
        val raw = File(path).absoluteFile
        val file = raw.canonicalFile
        validateDirectory(directory)
        require(raw.parentFile?.canonicalFile == directory.canonicalFile && file.parentFile == directory.canonicalFile &&
            !OsConstants.S_ISLNK(Os.lstat(raw.path).st_mode) &&
            OsConstants.S_ISREG(Os.lstat(file.path).st_mode) &&
            file.isFile && file.length() in 1..MAX_APK_BYTES) { "更新文件必须是应用专用暂存目录中的普通文件" }
        return file
    }

    private fun validateDirectory(directory: File) {
        require(root.canonicalFile.parentFile == activity.filesDir.canonicalFile &&
            directory.canonicalFile.parentFile == root.canonicalFile && directory.isDirectory &&
            !OsConstants.S_ISLNK(Os.lstat(root.path).st_mode) &&
            !OsConstants.S_ISLNK(Os.lstat(directory.path).st_mode)) { "更新暂存目录路径别名被拒绝" }
    }

    private fun fileHash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(128 * 1024)
            while (true) { checkCancelled(); val n = stream.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return hex(digest.digest())
    }
    private fun digest(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
    private fun signingFlags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
    private fun checkCancelled() { if (cancelled.get()) throw Cancelled() }
    private fun cleanupCancelled() { activeStaged?.let { if (it.canonicalPath != handedOff) it.delete() }; activeStaged = null }
    private fun progress(phase: String, bytes: Long, total: Long?) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (phase == "copy" && now - lastProgress < 100 && bytes != total) return
        lastProgress = now
        activity.runOnUiThread { channel.invokeMethod("progress", mapOf("phase" to phase, "bytes" to bytes, "total" to total)) }
    }
    fun close() {
        cancelled.set(true)
        runCatching { input?.close() }
        picker?.error("cancelled", "APK 选择已取消", null)
        picker = null
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
    private class Cancelled : RuntimeException()
    companion object {
        const val REQUEST_PICK_APK = 8641
        const val MAX_APK_BYTES = 512L * 1024 * 1024
        const val PRODUCTION_SIGNER = "9b474750e4c2af300eb5a0207bfb9e477030f22bb390a7da7a40d3854edec077"
        private val HASH = Regex("^[a-f0-9]{64}$")

        fun verifiedSigner(file: File, platform: Int): String {
            val verified = ApkVerifier.Builder(file).setMinCheckedPlatformVersion(platform)
                .setMaxCheckedPlatformVersion(platform).build().verify()
            require(verified.isVerified && verified.signerCertificates.size == 1) { "APK 密码学签名无效或不是单签名" }
            return MessageDigest.getInstance("SHA-256").digest(verified.signerCertificates.single().encoded)
                .joinToString("") { "%02x".format(it) }
        }

        fun updateDecision(currentPackage: String, currentVersion: Long, currentSigner: String, currentHash: String,
            packageName: String, version: Long, signer: String, hash: String, signatureVerified: Boolean): String {
            require(HASH.matches(currentHash) && HASH.matches(hash)) { "SHA-256 必须是完整散列" }
            return when {
                packageName != currentPackage -> "wrongPackage"
                !signatureVerified || !HASH.matches(currentSigner) || signer != currentSigner -> "wrongSigner"
                version < currentVersion -> "downgrade"
                version == currentVersion && hash != currentHash -> "sameVersionChanged"
                version == currentVersion -> "alreadyInstalled"
                else -> "upgrade"
            }
        }
    }
}
