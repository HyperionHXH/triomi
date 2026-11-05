package io.github.hyperionhxh.triomi

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.util.Locale

/** A persisted grant is not proof that an uninstall-scoped tree is portable. */
object BackupDestinationPolicy {
    fun isUninstallScoped(treeDocumentId: String, packageName: String): Boolean {
        val normalized = treeDocumentId.replace('\\', '/').lowercase(Locale.ROOT)
        val path = normalized.substringAfter(':').split('/').filter { it.isNotEmpty() }
        for (index in 0 until path.size - 1) {
            if (path[index] != "android") continue
            if (path[index + 1] == "data" || path[index + 1] == "obb") return true
            if (path[index + 1] == "media" && path.getOrNull(index + 2) == packageName.lowercase(Locale.ROOT)) return true
        }
        return false
    }

    fun validatePersistentTree(context: Context, uri: Uri) {
        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri))
        require(uri.authority != "${context.packageName}.fileprovider")
        require(!isUninstallScoped(DocumentsContract.getTreeDocumentId(uri), context.packageName)) {
            "备份目录会随卸载删除，请选择其他目录"
        }
        check(context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }) { "目录持久权限已失效，请重新授权" }
    }
}
