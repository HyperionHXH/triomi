package io.github.hyperionhxh.triomi

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.os.Build
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppUpdatePolicyTest {
    private val packageName = "io.github.hyperionhxh.triomi"
    private val hash = "1".repeat(64)
    private val signer = "2".repeat(64)
    private fun decision(version: Long = 148, offeredPackage: String = packageName,
        offeredSigner: String = signer, offeredHash: String = hash, verified: Boolean = true) =
        AppUpdateHost.updateDecision(packageName, 147, signer, hash,
            offeredPackage, version, offeredSigner, offeredHash, verified)

    @Test fun refusesWrongPackageSignerAndUnverifiedBytes() {
        assertEquals("wrongPackage", decision(offeredPackage = "org.other.app"))
        assertEquals("wrongSigner", decision(offeredSigner = AppUpdateHost.PRODUCTION_SIGNER))
        assertEquals("wrongSigner", decision(verified = false))
        assertEquals("upgrade", decision())
    }
    @Test fun refusesDowngradeAndSameVersionChanged() {
        assertEquals("downgrade", decision(version = 146))
        assertEquals("sameVersionChanged", decision(version = 147, offeredHash = "3".repeat(64)))
        assertEquals("alreadyInstalled", decision(version = 147))
    }
    @Test fun refusesTruncatedHashBeforeInstaller() {
        assertThrows(IllegalArgumentException::class.java) { decision(offeredHash = "abcd") }
    }
    @Test fun staticVerificationReadsActualInstalledApkAndRejectsTruncation() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val installed = File(context.applicationInfo.sourceDir)
        val fingerprint = AppUpdateHost.verifiedSigner(installed, Build.VERSION.SDK_INT)
        assertEquals(64, fingerprint.length)
        val truncated = File.createTempFile("triomi-update-truncated-", ".apk", context.cacheDir)
        try {
            installed.inputStream().use { input ->
                truncated.outputStream().use { output ->
                    val buffer = ByteArray(4096)
                    val count = input.read(buffer)
                    output.write(buffer, 0, count)
                }
            }
            assertThrows(Exception::class.java) { AppUpdateHost.verifiedSigner(truncated, Build.VERSION.SDK_INT) }
        } finally { truncated.delete() }
    }
}
