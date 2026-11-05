package io.github.hyperionhxh.triomi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** SAF originals are never confused with private, disposable import snapshots. */
class BackupDocumentHost(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "triomi/backupDocuments")
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var request = 0
    private val stagedLeases = mutableMapOf<String, String>()
    @Volatile private var closed = false
    private val resolver get() = activity.contentResolver

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory", "pickBackup" -> {
                    if (pending != null) result.error("busy", "文档选择器已打开", null)
                    else {
                        pending = result
                        request = if (call.method == "pickDirectory") 4191 else 4192
                        try {
                            activity.startActivityForResult(Intent(if (request == 4191)
                                Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                                if (request == 4192) { addCategory(Intent.CATEGORY_OPENABLE); type = "application/zip" }
                            }, request)
                        } catch (_: Exception) {
                            pending = null
                            result.error("picker_failed", "系统文档选择器不可用", null)
                        }
                    }
                }
                else -> worker.execute {
                    try {
                        val output: Any? = when (call.method) {
                            "list" -> list(Uri.parse(requireNotNull(call.argument<String>("treeUri"))))
                            "stage" -> stage(Uri.parse(requireNotNull(call.argument<String>("uri"))))
                            "releaseStage" -> {
                                val path = requireNotNull(call.argument<String>("path"))
                                val token = synchronized(stagedLeases) { stagedLeases.remove(path) }
                                BackupArtifactGuard.release(token)
                                null
                            }
                            "delete" -> {
                                val uri = Uri.parse(requireNotNull(call.argument<String>("uri")))
                                val expected = requireNotNull(call.argument<String>("sha256"))
                                require(expected.matches(Regex("[0-9a-f]{64}")))
                                val digest = MessageDigest.getInstance("SHA-256")
                                requireNotNull(resolver.openInputStream(uri)).use { input ->
                                    val buffer = ByteArray(128 * 1024)
                                    while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
                                }
                                check(digest.digest().joinToString("") { "%02x".format(it) } == expected) { "原备份已改变，拒绝删除" }
                                DocumentsContract.deleteDocument(resolver, uri)
                            }
                            else -> { activity.runOnUiThread { result.notImplemented() }; return@execute }
                        }
                        activity.runOnUiThread { result.success(output) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { result.error("document_failed", "备份目录或文件不可用；请检查或重新授予权限。原文件不会自动删除。", null) }
                    }
                }
            }
        }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != 4191 && code != 4192) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        try {
            val granted = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (code == 4191) {
                check(granted and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0 && granted and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0)
                val treeId = DocumentsContract.getTreeDocumentId(uri)
                require(!BackupDestinationPolicy.isUninstallScoped(treeId, activity.packageName))
                resolver.takePersistableUriPermission(uri, granted)
                BackupDestinationPolicy.validatePersistentTree(activity, uri)
                val root = DocumentsContract.buildDocumentUriUsingTree(uri, treeId)
                var label = uri.toString()
                resolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
                    check(cursor.moveToFirst())
                    check(cursor.getLong(1) and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE.toLong() != 0L)
                    label = "${cursor.getString(0)}\n$uri"
                } ?: error("目录不可读取")
                result.success(mapOf("uri" to uri.toString(), "label" to label))
            } else {
                // Permission may not include write/delete. Restore remains useful;
                // the optional post-success delete reports a denial honestly.
                try { resolver.takePersistableUriPermission(uri, granted) } catch (_: SecurityException) { }
                worker.execute {
                    try {
                        val path = stage(uri)
                        activity.runOnUiThread { result.success(mapOf("uri" to uri.toString(), "path" to path)) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { result.error("read_failed", "无法读取原备份", null) }
                    }
                }
            }
        } catch (_: Exception) { result.error("grant_failed", "目录未提供持久读写权限，请重新选择其他目录", null) }
        return true
    }

    private fun list(tree: Uri): List<Map<String, Any>> {
        BackupDestinationPolicy.validatePersistentTree(activity, tree)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val rows = mutableListOf<Map<String, Any>>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                if (!name.endsWith(".zip", true) || cursor.getString(3) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                rows.add(mapOf("uri" to DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)).toString(),
                    "name" to name, "size" to cursor.getLong(2)))
            }
        } ?: error("目录不可读取")
        return rows.sortedByDescending { it["name"].toString() }
    }

    private fun stage(uri: Uri): String {
        require(uri.scheme == "content")
        val lease = BackupArtifactGuard.acquire(activity.applicationContext)
            ?: error("备份存储正在恢复，请稍后重试")
        var file: File? = null
        try {
            val directory = File(activity.cacheDir.canonicalFile, "backup-imports").apply { mkdirs() }
            check(directory.isDirectory && directory.absoluteFile == directory.canonicalFile)
            val outputFile = File.createTempFile("backup-", ".zip", directory)
            file = outputFile
            requireNotNull(resolver.openInputStream(uri)).use { input -> outputFile.outputStream().use { output ->
                val buffer = ByteArray(128 * 1024)
                var total = 0L
                while (true) { val count = input.read(buffer); if (count < 0) break
                    total += count; check(total <= 128L * 1024 * 1024 * 1024) { "备份文件过大" }; output.write(buffer, 0, count) }
            } }
            check(outputFile.length() > 0)
            synchronized(stagedLeases) {
                check(!closed)
                stagedLeases[outputFile.path] = lease
            }
            return outputFile.path
        } catch (error: Exception) {
            file?.delete()
            BackupArtifactGuard.release(lease)
            throw error
        }
    }
    fun close() {
        closed = true
        synchronized(stagedLeases) {
            for (lease in stagedLeases.values) BackupArtifactGuard.release(lease)
            stagedLeases.clear()
        }
        channel.setMethodCallHandler(null)
        pending?.error("cancelled", "文档选择已取消", null)
        pending = null
        worker.shutdown()
    }
}
