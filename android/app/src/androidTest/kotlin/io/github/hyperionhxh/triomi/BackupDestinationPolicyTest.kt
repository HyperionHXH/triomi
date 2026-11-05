package io.github.hyperionhxh.triomi

import android.net.Uri
import android.provider.DocumentsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BackupDestinationPolicyTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun rejectsEveryUninstallScopedPackageTreeIncludingExternalMedia() {
        val pkg = context.packageName
        for (id in listOf("primary:Android/data/$pkg", "primary:Android/obb/$pkg/sub",
            "primary:Android/media/$pkg", "primary:ANDROID/MEDIA/$pkg/backups")) {
            assertTrue(id, BackupDestinationPolicy.isUninstallScoped(id, pkg))
            val tree = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", id)
            assertThrows(IllegalArgumentException::class.java) {
                BackupDestinationPolicy.validatePersistentTree(context, tree)
            }
            // Saved destinations are checked by the actual export writer too,
            // before any document creation or provider write is attempted.
            assertThrows(IllegalArgumentException::class.java) {
                SafDocumentWriter.write(context, tree.toString(), "backup.zip", "application/zip", byteArrayOf(1), null)
            }
        }
        assertFalse(BackupDestinationPolicy.isUninstallScoped("primary:Download/Triomi", pkg))
        assertFalse(BackupDestinationPolicy.isUninstallScoped("primary:Android/media/${pkg}.other", pkg))
        assertFalse(BackupDestinationPolicy.isUninstallScoped("primary:MyAndroid/media/$pkg", pkg))
    }

    @Test fun revokedOrAbsentPersistentGrantFailsBeforeSavedExport() {
        val tree = DocumentsContract.buildTreeDocumentUri("triomi.invalid.revoked.provider", "backups")
        assertThrows(IllegalStateException::class.java) {
            BackupDestinationPolicy.validatePersistentTree(context, tree)
        }
        assertThrows(IllegalStateException::class.java) {
            SafDocumentWriter.write(context, tree.toString(), "backup.zip", "application/zip", byteArrayOf(1), null)
        }
        assertThrows(IllegalArgumentException::class.java) {
            BackupDestinationPolicy.validatePersistentTree(context, Uri.parse("file:///private/backup"))
        }
    }

    @Test fun stagedOperationLeaseExcludesRecoveryUntilReleased() {
        val lease = BackupArtifactGuard.acquire(context)
        check(lease != null)
        try { assertTrue(BackupArtifactGuard.acquire(context, cleanup = true) == null) }
        finally { BackupArtifactGuard.release(lease) }
        val cleanup = BackupArtifactGuard.acquire(context, cleanup = true)
        check(cleanup != null)
        BackupArtifactGuard.release(cleanup)
    }
}
