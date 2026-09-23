package io.github.hyperionhxh.triomi

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingFontResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "triomi/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFontFile" -> {
                        pendingFontResult = result
                        launchFontPicker()
                    }
                    else -> result.notImplemented()
                }
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

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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
    }
}
