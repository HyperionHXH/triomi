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

class MainActivity : FlutterActivity() {
    private var pendingFontResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "triomi/native-video",
            NativeVideoViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "triomi/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
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

    /** 向授权目录写文件：DocumentsContract.createDocument + 输出流。 */
    private fun writeToTree(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")
        val fileName = call.argument<String>("fileName") ?: "export.zip"
        val bytes = call.argument<ByteArray>("bytes")
        val mime = call.argument<String>("mime") ?: "application/zip"
        if (treeUri == null || bytes == null) {
            result.error("invalid_args", "treeUri and bytes are required", null)
            return
        }
        try {
            val root = Uri.parse(treeUri)
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                root,
                DocumentsContract.getTreeDocumentId(root),
            )
            val newUri = DocumentsContract.createDocument(
                contentResolver, docUri, mime, fileName,
            )
            if (newUri == null) {
                result.error("create_failed", "createDocument returned null", null)
                return
            }
            val stream = contentResolver.openOutputStream(newUri)
                ?: throw java.io.IOException("Unable to open document output stream")
            stream.use { output ->
                output.write(bytes)
                output.flush()
            }
            result.success(newUri.toString())
        } catch (error: Exception) {
            result.error("write_failed", error.message, null)
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
        private const val REQUEST_NOTIFICATION = 4104
    }
}
