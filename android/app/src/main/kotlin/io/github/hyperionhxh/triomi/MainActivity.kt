package io.github.hyperionhxh.triomi

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var videoResolver: WebVideoResolver? = null
    private var downloadVideoResolver: WebVideoResolver? = null
    private var mihonWebSession: MihonWebSession? = null
    private var mihonSessionPending = false
    private lateinit var mihonHost: MihonHost
    private var pendingFontResult: MethodChannel.Result? = null
    private var pendingBackupResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private val mihonExecutor = Executors.newCachedThreadPool()
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private var videoPipEnabled = false
    private var videoBackgroundAudio = false
    private var videoPolicyOwner: String? = null
    private var privacyLockProtected = true
    private var privacyLockBlocked = true
    private var nativeForeground = false
    private var consentGeneration = 0L

    fun updateConsentGeneration(): Long = consentGeneration
    fun updateConsentCurrent(generation: Long): Boolean =
        generation == consentGeneration && nativeForeground && hasWindowFocus() &&
            !isFinishing && !isDestroyed && (!privacyLockProtected || !privacyLockBlocked)

    private fun invalidateNativeConsent() {
        consentGeneration++
        if (privacyLockProtected) {
            privacyLockBlocked = true
            mihonWebSession?.close()
            videoResolver?.cancel()
            downloadVideoResolver?.cancel()
            NativeVideoLifecycle.active?.onBackground(false)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) invalidateNativeConsent()
    }
    private val localComicPicker by lazy { LocalComicPicker(this) }
    private lateinit var appUpdateHost: AppUpdateHost

    private fun notificationRoute(value: Intent): String? =
        value.getStringExtra("triomi_route")?.takeIf { it == "/anime" || it == "/manga/updates" }

    override fun getInitialRoute(): String? = notificationRoute(intent) ?: super.getInitialRoute()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appUpdateHost = AppUpdateHost(this, flutterEngine.dartExecutor.binaryMessenger)
        SecureStorePersistence.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // Secure from the first native frame; Dart clears this only if the
        // device-local lock is disabled. Enabled locks also disallow PiP.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "triomi/privacy-lock")
            .setMethodCallHandler { call, result ->
                if (call.method != "protect") {
                    result.notImplemented()
                } else {
                    val values = call.arguments as? Map<*, *>
                    val enabled = values?.get("enabled") == true
                    val blocked = values?.get("blocked") == true
                    if (blocked && !privacyLockBlocked) invalidateNativeConsent()
                    privacyLockProtected = enabled
                    privacyLockBlocked = blocked
                    if (enabled && blocked) {
                        mihonWebSession?.close()
                        videoResolver?.cancel()
                        downloadVideoResolver?.cancel()
                    }
                    if (privacyLockProtected) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
            }
        BackupArtifactGuard.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        JsWorkerController(this, flutterEngine)
        mihonHost = MihonHost(this)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "triomi/native-video",
            NativeVideoViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "triomi/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickLocalComic" -> localComicPicker.pick(result, call.argument<Boolean>("directory") == true)
                    "cancelLocalComicPick" -> { localComicPicker.cancel(); result.success(null) }
                    "availableDiskBytes" -> {
                        try {
                            val path = requireNotNull(call.argument<String>("path"))
                            result.success(android.os.StatFs(path).availableBytes)
                        } catch (_: Exception) {
                            result.error("disk_unavailable", "cannot inspect destination disk", null)
                        }
                    }
                    "pickBackupFile" -> {
                        if (pendingBackupResult != null) result.error("busy", "Backup picker is already open", null)
                        else {
                            pendingBackupResult = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "*/*"
                                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/octet-stream"))
                                }, REQUEST_PICK_BACKUP)
                            } catch (_: Exception) {
                                pendingBackupResult = null
                                result.error("picker_failed", "Backup picker unavailable", null)
                            }
                        }
                    }
                    "scheduleLocalBackups" -> result.success(LocalBackupJobService.schedule(this, call.arguments == true))
                    "beginMangaUpdate" -> result.success(MangaUpdatesRuntime.begin(this))
                    "endMangaUpdate" -> { MangaUpdatesRuntime.end(this); result.success(null) }
                    "beginDownloadQueue" -> result.success(MangaUpdatesRuntime.beginDownloads(this))
                    "endDownloadQueue" -> { MangaUpdatesRuntime.endDownloads(this); result.success(null) }
                    "canNotifyMangaUpdates" -> result.success(BackgroundUpdate.hasNotificationPermission(this))
                    "cancelMangaUpdate" -> {
                        MangaUpdatesRuntime.cancel()
                        result.success(true)
                    }
                    "mangaUpdateConstraints" -> result.success(MangaUpdatesRuntime.allowed(this,
                        call.argument<Boolean>("wifiOnly") != false, call.argument<Boolean>("batteryNotLow") != false))
                    "scheduleMangaUpdates" -> result.success(MangaUpdatesRuntime.schedule(this,
                        call.argument<Boolean>("enabled") == true, call.argument<Boolean>("wifiOnly") != false,
                        call.argument<Boolean>("batteryNotLow") != false))
                    "notifyMangaUpdate" -> {
                        MangaUpdatesRuntime.notify(this, call.argument<String>("id") ?: "manga",
                            call.argument<String>("title") ?: "漫画更新", call.argument<String>("body") ?: "",
                            call.argument<String>("coverPath"))
                        result.success(true)
                    }
                    "videoPolicy" -> {
                        val owner = call.argument<String>("owner")
                        val active = call.argument<Boolean>("active") == true
                        if (!active && owner != videoPolicyOwner) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        videoPolicyOwner = if (active) owner else null
                        videoPipEnabled = call.argument<Boolean>("pip") == true
                        videoBackgroundAudio = call.argument<Boolean>("backgroundAudio") == true
                        val brightness = call.argument<Number>("brightness")?.toFloat()
                        if (brightness != null) {
                            window.attributes = window.attributes.apply {
                                screenBrightness = if (brightness < 0) -1f else brightness.coerceIn(.05f, 1f)
                            }
                        }
                        if (call.argument<Boolean>("active") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    "enterVideoPip" -> {
                        val supported = !privacyLockProtected && Build.VERSION.SDK_INT >= 26 &&
                            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                        result.success(supported && enterPictureInPictureMode(
                            android.app.PictureInPictureParams.Builder()
                                .setAspectRatio(android.util.Rational(16, 9)).build(),
                        ))
                    }
                    "ruleOpenSession" -> {
                        val requestGeneration = updateConsentGeneration()
                        val url = call.argument<String>("url")
                        val uri = runCatching { android.net.Uri.parse(url) }.getOrNull()
                        if (uri?.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) {
                            result.error("invalid_url", "rule session requires HTTPS", null)
                        } else if (!updateConsentCurrent(requestGeneration)) {
                            result.error("privacy_locked", "unlock before opening source browser", null)
                        } else if (mihonSessionPending) {
                            result.error("session_busy", "a source browser is already open", null)
                        } else {
                            mihonSessionPending = true
                            try {
                                val session = MihonWebSession(
                                    this, url!!,
                                    call.argument<String>("userAgent").orEmpty(),
                                ) { saved ->
                                    mihonWebSession = null
                                    if (mihonSessionPending) {
                                        mihonSessionPending = false
                                        result.success(mapOf("ok" to true, "saved" to saved))
                                    }
                                }
                                mihonWebSession = session
                                session.show()
                            } catch (error: Exception) {
                                mihonSessionPending = false
                                mihonWebSession?.close()
                                mihonWebSession = null
                                result.error("browser_failed", "rule browser unavailable", null)
                            }
                        }
                    }
                    "ruleCookieHeader", "ruleStoreCookies" -> {
                        val url = call.argument<String>("url")
                        val uri = runCatching { android.net.Uri.parse(url) }.getOrNull()
                        if (uri?.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) {
                            result.error("invalid_url", "rule cookies require HTTPS", null)
                        } else {
                            val manager = android.webkit.CookieManager.getInstance()
                            if (call.method == "ruleCookieHeader") {
                                result.success(manager.getCookie(url!!))
                            } else {
                                val cookies = call.argument<List<String>>("cookies").orEmpty()
                                if (cookies.isEmpty()) {
                                    result.success(true)
                                } else {
                                    var remaining = cookies.size
                                    cookies.forEach { cookie ->
                                        manager.setCookie(url!!, cookie) {
                                            remaining--
                                            if (remaining == 0) {
                                                manager.flush()
                                                result.success(true)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    "mihonOpenSession" -> {
                        val requestGeneration = updateConsentGeneration()
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("invalid_args", "source arguments are required", null)
                        } else if (mihonSessionPending) {
                            result.error("session_busy", "a source browser is already open", null)
                        } else if (!updateConsentCurrent(requestGeneration)) {
                            result.error("privacy_locked", "unlock before opening source browser", null)
                        } else {
                            mihonSessionPending = true
                            mihonExecutor.execute {
                                try {
                                    val info = mihonHost.request(args + ("operation" to "browserInfo"))
                                    runOnUiThread {
                                        if (!updateConsentCurrent(requestGeneration)) {
                                            mihonSessionPending = false
                                            result.error("activity_closed", "source browser was cancelled", null)
                                        } else {
                                            try {
                                                val session = MihonWebSession(
                                                    this, info["url"] as String, info["userAgent"] as String,
                                                ) { saved ->
                                                    mihonWebSession = null
                                                    if (mihonSessionPending) {
                                                        mihonSessionPending = false
                                                        result.success(mapOf("ok" to true, "saved" to saved))
                                                    }
                                                }
                                                mihonWebSession = session
                                                session.show()
                                            } catch (error: Exception) {
                                                mihonSessionPending = false
                                                mihonWebSession?.close()
                                                mihonWebSession = null
                                                result.error("browser_failed", error.message, null)
                                            }
                                        }
                                    }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        mihonSessionPending = false
                                        result.error("mihon_session_failed", error.message, null)
                                    }
                                }
                            }
                        }
                    }
                    "mihonInspect" -> {
                        mihonExecutor.execute {
                            val inspected = mihonHost.inspect(
                                call.argument<String>("apkPath"),
                                call.argument<String>("packageName"),
                                call.argument<Number>("versionCode")?.toLong(),
                                call.argument<String>("signerSha256"),
                                call.argument<String>("apkSha256"),
                            )
                            runOnUiThread { result.success(inspected) }
                        }
                    }
                    "mihonInspectMetadata" -> {
                        mihonExecutor.execute {
                            val metadata = mihonHost.metadata(call.argument<String>("apkPath"),
                                call.argument<String>("packageName"), call.argument<Number>("versionCode")?.toLong())
                            runOnUiThread { result.success(metadata) }
                        }
                    }
                    "mihonSetEnabled" -> {
                        val packageName = call.argument<String>("packageName")
                        val enabled = call.argument<Boolean>("enabled")
                        if (packageName == null || enabled == null) {
                            result.error("invalid_args", "packageName and enabled are required", null)
                        } else {
                            result.success(mihonHost.setEnabled(packageName, enabled))
                        }
                    }
                    "mihonOpenSettings" -> {
                        val requestGeneration = updateConsentGeneration()
                        val pkg = call.argument<String>("packageName")
                        val sourceId = call.argument<String>("sourceId")
                        if (pkg == null || sourceId == null) {
                            result.error("invalid_args", "source identity required", null)
                        } else if (!updateConsentCurrent(requestGeneration)) {
                            result.error("privacy_locked", "unlock before opening source settings", null)
                        } else {
                            mihonExecutor.execute {
                                try {
                                    mihonHost.settingsSource(pkg, sourceId)
                                    runOnUiThread {
                                        if (!updateConsentCurrent(requestGeneration)) {
                                            result.error("privacy_locked", "source settings consent expired", null)
                                            return@runOnUiThread
                                        }
                                        startActivity(Intent(this, MihonSettingsActivity::class.java)
                                            .putExtra("packageName", pkg).putExtra("sourceId", sourceId)
                                            .putExtra("privacyLock", privacyLockProtected))
                                        result.success(true)
                                    }
                                } catch (error: Throwable) {
                                    runOnUiThread { result.error("settings_unavailable", error.message, null) }
                                }
                            }
                        }
                    }
                    "mihonRequest" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("invalid_args", "request arguments are required", null)
                        } else {
                            mihonExecutor.execute {
                                try {
                                    val payload = mihonHost.request(args)
                                    runOnUiThread { result.success(payload) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error("mihon_request_failed", error.message ?: error.javaClass.simpleName, null)
                                    }
                                }
                            }
                        }
                    }
                    "resolveVideo" -> {
                        videoResolver?.cancel()
                        videoResolver = WebVideoResolver(this)
                        videoResolver?.resolve(call, result)
                    }
                    "resolveDownloadVideo" -> {
                        downloadVideoResolver?.cancel()
                        downloadVideoResolver = WebVideoResolver(this)
                        downloadVideoResolver?.resolve(call, result)
                    }
                    "cancelDownloadVideoResolve" -> {
                        downloadVideoResolver?.cancel()
                        result.success(null)
                    }
                    "cancelVideoResolve" -> {
                        videoResolver?.cancel(call.argument<String>("requestId"))
                        result.success(null)
                    }
                    "pickFontFile" -> {
                        pendingFontResult = result
                        launchFontPicker()
                    }
                    "keepScreenOn" -> {
                        // 屏幕常亮：阅读器进页面时开、退出时关。
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    "saveImageToGallery" -> {
                        saveImageToGallery(call, result)
                    }
                    "pickDirectory" -> {
                        pendingFontResult = result
                        launchDirectoryPicker()
                    }
                    "writeToTree" -> {
                        writeToTree(call, result)
                    }
                    "pickImage" -> {
                        pendingFontResult = result
                        launchImagePicker()
                    }
                    "scheduleBackgroundCheck" -> {
                        // 后台更新提醒（T7-7）：开启时注册周期任务，关闭时取消。
                        if (call.arguments == true) {
                            result.success(BackgroundUpdate.schedule(this))
                        } else {
                            BackgroundUpdate.cancel(this)
                            result.success(true)
                        }
                    }
                    "backgroundCheckScheduled" -> {
                        result.success(BackgroundUpdate.isScheduled(this))
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermission(result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        notificationRoute(intent)?.let { flutterEngine?.navigationChannel?.pushRouteInformation(it) }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!privacyLockProtected && videoPipEnabled && Build.VERSION.SDK_INT >= 26 &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            enterPictureInPictureMode(android.app.PictureInPictureParams.Builder()
                .setAspectRatio(android.util.Rational(16, 9)).build())
        }
    }

    override fun onPictureInPictureModeChanged(inPip: Boolean, configuration: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(inPip, configuration)
        NativeVideoLifecycle.inPip = inPip
        NativeVideoLifecycle.active?.onPipChanged(inPip)
    }

    override fun onPause() {
        super.onPause()
        nativeForeground = false
        invalidateNativeConsent()
        val pip = Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode
        NativeVideoLifecycle.active?.onBackground(!privacyLockProtected && (videoBackgroundAudio || pip))
        if (privacyLockProtected) {
            mihonWebSession?.close()
            videoResolver?.cancel()
            downloadVideoResolver?.cancel()
        }
    }

    override fun onResume() {
        super.onResume()
        nativeForeground = true
        if (privacyLockProtected) NativeVideoLifecycle.active?.onBackground(false)
        else NativeVideoLifecycle.active?.onForeground()
    }

    override fun onDestroy() {
        localComicPicker.close()
        if (::appUpdateHost.isInitialized) appUpdateHost.close()
        mihonWebSession?.close()
        videoResolver?.cancel()
        downloadVideoResolver?.cancel()
        mihonExecutor.shutdownNow()
        exportExecutor.shutdownNow()
        MangaUpdatesRuntime.end(this)
        MangaUpdatesRuntime.endDownloads(this)
        super.onDestroy()
    }

    /** SAF 目录选择（导出目录）。 */
    private fun launchDirectoryPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        try {
            startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
        } catch (error: Exception) {
            val pending = pendingFontResult
            pendingFontResult = null
            pending?.error("picker_failed", error.message, null)
        }
    }

    /** Copies exports on a storage worker, not the UI thread. */
    private fun writeToTree(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")
        val fileName = call.argument<String>("fileName") ?: "export.zip"
        val bytes = call.argument<ByteArray>("bytes")
        val sourcePath = call.argument<String>("sourcePath")
        val mime = call.argument<String>("mime") ?: "application/zip"
        if (treeUri == null || (bytes == null) == (sourcePath == null)) {
            result.error("invalid_args", "treeUri and exactly one export input are required", null)
            return
        }
        exportExecutor.execute {
            try {
                val uri = SafDocumentWriter.write(applicationContext, treeUri, fileName, mime, bytes, sourcePath)
                runOnUiThread { result.success(uri) }
            } catch (error: Exception) {
                runOnUiThread { result.error("write_failed", error.message, null) }
            }
        }
    }

    /** 保存图片到相册（MediaStore，Pictures/Triomi；Android 10+ 免存储权限）。 */
    private fun saveImageToGallery(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName") ?: "image.png"
        if (bytes == null) {
            result.error("invalid_args", "bytes is required", null)
            return
        }
        try {
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Triomi")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }
            val uri = contentResolver.insert(collection, values)
            if (uri == null) {
                result.error("insert_failed", "MediaStore insert returned null", null)
                return
            }
            contentResolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
                output.flush()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            }
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    /** SAF 选择一张图片（评论配图）：把字节直接回给 Dart（站点要求先上传再引用）。 */
    private fun launchImagePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*"))
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_IMAGE)
        } catch (error: Exception) {
            val pending = pendingFontResult
            pendingFontResult = null
            pending?.error("picker_failed", error.message, null)
        }
    }

    /** SAF 选择字体文件（ttf/otf）。 */
    private fun launchFontPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "font/ttf",
                    "font/otf",
                    "application/x-font-ttf",
                    "application/x-font-otf",
                    "application/octet-stream",
                ),
            )
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_FONT)
        } catch (error: Exception) {
            val pending = pendingFontResult
            pendingFontResult = null
            pending?.error("picker_failed", error.message, null)
        }
    }

    /**
     * 申请通知权限（Android 13+）。低版本或已授权直接回 true；
     * 首次申请由系统弹窗，结果在 onRequestPermissionsResult 里回给 Dart。
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (BackgroundUpdate.hasNotificationPermission(this)) {
            result.success(true)
            return
        }
        pendingNotificationResult = result
        requestPermissions(
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATION,
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATION) return
        val pending = pendingNotificationResult
        pendingNotificationResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending?.success(granted)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (localComicPicker.onActivityResult(requestCode, resultCode, data)) return
        if (::appUpdateHost.isInitialized && appUpdateHost.onActivityResult(requestCode, resultCode, data)) return
        if (requestCode == REQUEST_PICK_BACKUP) {
            val pending = pendingBackupResult
            pendingBackupResult = null
            if (pending == null) return
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) { pending.success(null); return }
            mihonExecutor.execute {
                // The returned picker path remains useful between review and
                // restore. Keep it pinned until process death on success; a
                // cold-start exclusive sweep removes this app-owned cache ZIP.
                val lease = BackupArtifactGuard.acquire(applicationContext)
                if (lease == null) {
                    runOnUiThread { pending.error("backup_busy", "Backup storage is busy", null) }
                    return@execute
                }
                try {
                    val file = java.io.File.createTempFile("backup-import-", ".zip", cacheDir)
                    try {
                        val input = contentResolver.openInputStream(uri) ?: throw java.io.IOException("Backup unavailable")
                        input.use { stream ->
                            file.outputStream().use { output ->
                                val buffer = ByteArray(64 * 1024)
                                // Local ZIPs are disk-backed, unlike bounded WebDAV buffers.
                                val copyLimit = cacheDir.usableSpace - 64L * 1024 * 1024
                                if (copyLimit <= 0) throw java.io.IOException("Insufficient backup cache space")
                                var total = 0L
                                while (true) {
                                    val count = stream.read(buffer)
                                    if (count < 0) break
                                    total += count
                                    if (total > copyLimit) throw java.io.IOException("Insufficient backup cache space")
                                    output.write(buffer, 0, count)
                                }
                            }
                        }
                        runOnUiThread { pending.success(file.absolutePath) }
                    } catch (error: Exception) { file.delete(); throw error }
                } catch (_: Exception) {
                    BackupArtifactGuard.release(lease)
                    runOnUiThread { pending.error("backup_read_failed", "Backup unavailable or cache disk space insufficient", null) }
                }
            }
            return
        }
        if (requestCode == REQUEST_PICK_DIRECTORY) {
            val pending = pendingFontResult
            pendingFontResult = null
            if (pending == null) return
            val uri: Uri? = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            // 持久授权：跨进程重启后仍可写入。
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (_: Exception) {
            }
            pending.success(uri.toString())
            return
        }
        if (requestCode == REQUEST_PICK_IMAGE) {
            val pending = pendingFontResult
            pendingFontResult = null
            if (pending == null) return
            val uri: Uri? = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                // 用户取消：返回 null，调用方静默处理。
                pending.success(null)
                return
            }
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes == null || bytes.isEmpty()) {
                    pending.success(null)
                    return
                }
                pending.success(
                    mapOf(
                        "bytes" to bytes,
                        "name" to (queryDisplayName(uri) ?: "comment.jpg"),
                        "mime" to (contentResolver.getType(uri) ?: "image/jpeg"),
                    )
                )
            } catch (error: Exception) {
                pending.error("read_failed", error.message, null)
            }
            return
        }
        if (requestCode != REQUEST_PICK_FONT) return
        val pending = pendingFontResult
        pendingFontResult = null
        if (pending == null) return
        val uri: Uri? = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            val name = queryDisplayName(uri) ?: "imported-font.ttf"
            val safeName = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fff]"), "_")
            val target = File(cacheDir, "picked-fonts/$safeName")
            target.parentFile?.mkdirs()
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            pending.success(target.absolutePath)
        } catch (error: Exception) {
            pending.error("copy_failed", error.message, null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        }
        return null
    }

    companion object {
        private const val REQUEST_PICK_FONT = 4101
        private const val REQUEST_PICK_DIRECTORY = 4102
        private const val REQUEST_PICK_IMAGE = 4103
        private const val REQUEST_PICK_BACKUP = 4105
        private const val REQUEST_NOTIFICATION = 4104
    }
}
