package io.github.hyperionhxh.triomi

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException

/** Publishes a new SAF document; a failed copy never leaves a partial backup. */
object SafDocumentWriter {
    fun write(
        context: Context,
        treeUri: String,
        fileName: String,
        mime: String,
        bytes: ByteArray?,
        sourcePath: String?,
    ): String {
        require((bytes == null) != (sourcePath == null)) { "Exactly one export input is required" }
        val source = sourcePath?.let {
            val root = File(context.applicationInfo.dataDir).canonicalFile
            val file = File(it).canonicalFile
            require(file.isFile && file.path.startsWith(root.path + File.separator)) {
                "Export input must be an application-private file"
            }
            file
        }
        val resolver = context.contentResolver
        val root = Uri.parse(treeUri)
        val parent = DocumentsContract.buildDocumentUriUsingTree(root, DocumentsContract.getTreeDocumentId(root))
        val created = DocumentsContract.createDocument(resolver, parent, mime, fileName)
            ?: throw IOException("Export document creation failed")
        try {
            (source?.inputStream() ?: ByteArrayInputStream(bytes!!)).use { input ->
                (resolver.openOutputStream(created) ?: throw IOException("Export output unavailable")).use { output ->
                    input.copyTo(output)
                    output.flush()
                }
            }
        } catch (error: Exception) {
            try {
                DocumentsContract.deleteDocument(resolver, created)
            } catch (cleanup: Exception) {
                error.addSuppressed(cleanup)
            }
            throw error
        }
        return created.toString()
    }
}
