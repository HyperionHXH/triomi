package io.github.hyperionhxh.triomi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InterruptedIOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Read-only SAF selection. Never persists permissions or changes originals. */
class LocalComicPicker(private val activity: Activity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private var pending: MethodChannel.Result? = null
    private var active = false
    private var closed = false
    private var treeSelection = false
    fun pick(result: MethodChannel.Result, directory: Boolean = false) {
        if (active || pending != null) { result.error("busy", "已有本地漫画选择/复制进行中", null); return }
        pending = result
        cancelled.set(false)
        treeSelection = directory
        try {
            val intent = if (directory) Intent(Intent.ACTION_OPEN_DOCUMENT_TREE) else
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/x-cbz", "application/vnd.comicbook+zip", "application/octet-stream", "image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"))
                }
            activity.startActivityForResult(intent, REQUEST)
        } catch (_: Exception) { pending = null; result.error("picker_failed", "无法打开本地文件选择器", null) }
    }
    fun cancel() { cancelled.set(true) }
    fun onActivityResult(request: Int, result: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        if (closed) return true
        val callback = pending ?: return true
        pending = null
        if (result != Activity.RESULT_OK || data == null || cancelled.get()) { callback.success(null); return true }
        if ((data.clipData?.itemCount ?: 1) > 5000) { callback.error("file_limit", "最多选择5000张图片", null); return true }
        val uris = buildList {
            val clip = data.clipData
            if (clip != null) { for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri) }
            else data.data?.let { add(it) }
        }
        if (uris.isEmpty() || uris.size > 5000) { callback.error("file_limit", "最多选择5000张图片或一个ZIP/CBZ", null); return true }
        active = true
        executor.execute {
            var directory: File? = null
            var lease: String? = null
            try {
                lease = BackupArtifactGuard.acquire(activity, false) ?: error("无法锁定私有存储")
                val root = File(activity.cacheDir.canonicalFile, "local-comic-input").apply { mkdirs() }
                require(root.isDirectory && root.absoluteFile == root.canonicalFile) { "私有输入目录无效" }
                val selection = java.nio.file.Files.createTempDirectory(root.toPath(), "selection-").toFile()
                directory = selection
                var total = 0L
                val paths = mutableListOf<String>()
                val selected = if (treeSelection) folderImages(uris.single()) else uris.map { it to displayName(it) }
                require(selected.isNotEmpty() && selected.size <= 5000) { "目录没有受支持图片或超过5000页" }
                val seen = mutableSetOf<String>()
                val buffer = ByteArray(65536)
                for ((uri, name) in selected) {
                    if (cancelled.get()) throw InterruptedIOException()
                    require(uri.scheme == "content") { "仅接受系统文档内容URI" }
                    val ext = name.substringAfterLast('.', "").lowercase()
                    val archive = ext in setOf("zip", "cbz")
                    require(archive || ext in setOf("png", "jpg", "jpeg", "webp", "gif", "avif")) { "仅支持ZIP/CBZ或PNG/JPEG/WebP/GIF/AVIF，不支持CBR" }
                    require(!archive || (!treeSelection && selected.size == 1)) { "ZIP/CBZ需要单独导入" }
                    val limit = if (archive) 1024L * 1024 * 1024 else 64L * 1024 * 1024
                    require(name.isNotBlank() && name.length <= 1024 && name.split('/').all(::safeName) && seen.add(name.lowercase())) { "文件名无效或重复" }
                    val destination = File(selection, name)
                    destination.parentFile!!.mkdirs()
                    var copied = 0L
                    activity.contentResolver.openInputStream(uri)?.use { input ->
                        destination.outputStream().use { output ->
                            while (true) {
                                if (cancelled.get()) throw InterruptedIOException()
                                val read = input.read(buffer)
                                if (read < 0) break
                                copied += read; total += read
                                require(copied <= limit && total <= 2L * 1024 * 1024 * 1024) { "所选文件超过导入大小限制" }
                                require(selection.usableSpace > read + 16L * 1024 * 1024) { "本地空间不足" }
                                output.write(buffer, 0, read)
                            }
                            output.flush()
                        }
                    } ?: error("无法读取所选文档")
                    require(copied > 0) { "所选文件为空" }
                    paths.add(destination.absolutePath)
                }
                if (cancelled.get()) throw InterruptedIOException()
                activity.runOnUiThread {
                    active = false
                    if (!closed) callback.success(mapOf("paths" to (if (treeSelection) listOf(selection.absolutePath) else paths), "directory" to selection.absolutePath))
                    else selection.deleteRecursively()
                }
            } catch (error: Exception) {
                directory?.deleteRecursively()
                activity.runOnUiThread {
                    active = false
                    if (!closed) {
                        if (cancelled.get()) callback.success(null)
                        else callback.error("import_read_failed", error.message ?: "无法读取所选文件", null)
                    }
                }
            } finally { lease?.let { BackupArtifactGuard.release(it) } }
        }
        return true
    }
    private fun safeName(name: String): Boolean =
        name.isNotBlank() && name != "." && name != ".." && name.length <= 240 &&
            name.none { it == '/' || it == '\\' || it == ':' || it == '\u0000' }

    private fun displayName(uri: Uri): String {
        var name = ""
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) name = cursor.getString(0).orEmpty()
        }
        require(safeName(name)) { "文件名无效" }
        return name
    }

    private fun folderImages(tree: Uri): List<Pair<Uri, String>> {
        require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree)) { "请选择系统图片目录" }
        val images = mutableListOf<Pair<Uri, String>>()
        var scanned = 0
        val visited = mutableSetOf<String>()
        fun collect(id: String, prefix: String, depth: Int) {
            require(depth <= 64 && visited.add(id)) { "目录嵌套过深或循环" }
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
            val cursor = activity.contentResolver.query(children, projection, null, null, null) ?: error("无法读取所选目录")
            cursor.use {
                while (it.moveToNext()) {
                    if (cancelled.get()) throw InterruptedIOException()
                    require(++scanned <= 20000) { "目录条目超过20000限制" }
                    val childId = it.getString(0)
                    val name = it.getString(1).orEmpty()
                    require(safeName(name)) { "目录包含不安全名称" }
                    val relative = if (prefix.isEmpty()) name else "$prefix/$name"
                    require(relative.length <= 1024) { "目录路径过长" }
                    if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                        collect(childId, relative, depth + 1)
                    } else if (name.substringAfterLast('.', "").lowercase() in setOf("png", "jpg", "jpeg", "webp", "gif", "avif")) {
                        require(images.size < 5000) { "图片数量超过5000页限制" }
                        images.add(DocumentsContract.buildDocumentUriUsingTree(tree, childId) to relative)
                    }
                }
            }
        }
        collect(DocumentsContract.getTreeDocumentId(tree), "", 0)
        return images
    }
    fun close() { closed = true; cancel(); pending = null; executor.shutdownNow() }
    companion object { private const val REQUEST = 8642 }
}
