package io.github.hyperionhxh.triomi

import android.os.Build
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppUpdateRetentionTest {
    private val packageName = "io.github.hyperionhxh.triomi"
    private val signer = "2".repeat(64)

    private inner class Fixture : AutoCloseable {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "update-retention-${UUID.randomUUID()}").apply { mkdirs() }
        val cache = File(root, "cache").apply { mkdirs() }
        val files = File(root, "files").apply { mkdirs() }
        var version = 173L
        val identity get() = AppUpdateRetention.Identity(packageName, version, signer)
        fun retention() = AppUpdateRetention(cache, files, installed = { identity }, inspect = { file ->
            val values = file.readText().split('|')
            AppUpdateRetention.Identity(values[0], values[1].toLong(), values[2])
        })
        fun candidate(retention: AppUpdateRetention, code: Long = 174): File {
            val incoming = retention.beginIncoming()
            incoming.writeText("$packageName|$code|$signer")
            val result = retention.copyIncoming(incoming.path) { source, target -> source.copyTo(target, overwrite = true) }
            assertFalse("download duplicate must be removed before candidate publication", incoming.exists())
            return result
        }
        override fun close() { root.deleteRecursively() }
    }

    @Test fun twoCompletedUpdatesAreReapedThroughOwnedStagingAfterRestart() {
        Fixture().use { fixture ->
            for (version in 174L..175L) {
                val running = fixture.retention()
                val candidate = fixture.candidate(running, version)
                running.beginHandoff(candidate)
                assertFalse("discard must report installer protection honestly", running.releaseCandidate(candidate))
                val restartedBeforeInstall = fixture.retention()
                assertTrue(restartedBeforeInstall.maintain(clear = true).protectedBytes > 0)
                assertTrue(candidate.exists())
                fixture.version = version
                val restartedAfterInstall = fixture.retention()
                assertTrue(restartedAfterInstall.maintain().removedBytes > 0)
                assertFalse(candidate.exists())
                assertEquals(0L, restartedAfterInstall.storageInfo().installBytes)
            }
        }
    }

    @Test fun cancellationRetainsVisibleRetryAndDisposalReleasesItAfterInstallerReturns() {
        Fixture().use { fixture ->
            val retention = fixture.retention()
            val candidate = fixture.candidate(retention)
            retention.beginHandoff(candidate)
            retention.finishHandoff()
            assertTrue(candidate.exists())
            retention.beginHandoff(candidate) // Explicit retry after system cancellation.
            retention.beginHandoff(candidate) // Same-path recovery never deletes installer bytes.
            assertFalse(retention.releaseCandidate(candidate))
            assertTrue(candidate.exists())
            retention.finishHandoff()
            assertTrue("a rejected removal retains visible retry ownership", candidate.exists())
            assertTrue(retention.releaseCandidate(candidate))
            assertFalse(candidate.exists())
        }
    }

    @Test fun pendingNewerLeaseSurvivesRestartAndCannotBeReplaced() {
        Fixture().use { fixture ->
            val first = fixture.retention()
            val pending = fixture.candidate(first)
            first.beginHandoff(pending)
            first.close()
            val restarted = fixture.retention()
            assertNotNull(restarted.pendingCandidate())
            val replacement = fixture.candidate(restarted, 175)
            assertThrows(IllegalArgumentException::class.java) { restarted.beginHandoff(replacement) }
            restarted.maintain(clear = true)
            assertTrue(pending.exists())
            assertTrue(replacement.exists())
            restarted.releaseCandidate(replacement)
            assertFalse(restarted.releaseCandidate(pending))
            restarted.finishHandoff()
            assertTrue(pending.exists())
            assertTrue(restarted.releaseCandidate(pending))
            assertFalse(pending.exists())
        }
    }

    @Test fun scansDoNotDeleteAndActiveDownloadsCopiesAndVerificationAreExcluded() {
        Fixture().use { fixture ->
            val retention = fixture.retention()
            val active = retention.beginIncoming().apply { writeText("partial") }
            val candidate = fixture.candidate(retention)
            val legacyIncoming = File(fixture.files, "app-update/incoming").apply { mkdirs() }
            val abandoned = File(legacyIncoming, "download-1723456789012345.apk").apply { writeText("old duplicate") }
            val scan = retention.storageInfo()
            assertTrue(scan.reclaimableBytes >= abandoned.length())
            assertTrue(abandoned.exists())
            retention.maintain(clear = true)
            assertTrue(active.exists())
            assertTrue(candidate.exists())
            assertFalse(abandoned.exists())
            retention.finishIncoming(active.path)
            retention.releaseCandidate(candidate)
            val empty = retention.storageInfo()
            assertEquals(0L, empty.incomingBytes + empty.installBytes + empty.legacyBytes)
        }
    }

    @Test fun legacyInstalledAndWrongSignerStagesAreReclaimedButNewerVerifiedLegacyIsProtected() {
        Fixture().use { fixture ->
            val retention = fixture.retention()
            val legacy = File(fixture.files, "app-update/install").apply { mkdirs() }
            fun stage(packageValue: String, version: Long, signerValue: String) =
                File(legacy, "${UUID.randomUUID()}.apk").apply { writeText("$packageValue|$version|$signerValue") }
            val installed = stage(packageName, 173, signer)
            val obsolete = stage(packageName, 172, signer)
            val newer = stage(packageName, 174, signer)
            val wrongSigner = stage(packageName, 174, "3".repeat(64))
            val wrongPackage = stage("other.package", 174, signer)
            retention.maintain()
            assertFalse(installed.exists())
            assertFalse(obsolete.exists())
            assertTrue(wrongSigner.exists())
            assertTrue(wrongPackage.exists())
            assertTrue(newer.exists())
            retention.maintain(clear = true)
            assertFalse(installed.exists())
            assertFalse(obsolete.exists())
            assertFalse(wrongSigner.exists())
            assertFalse(wrongPackage.exists())
            assertTrue(newer.exists())
            fixture.version = 174
            retention.maintain()
            assertFalse(newer.exists())
        }
    }

    @Test fun malformedNamesDirectoriesAndSymlinksAreNeverFollowedOrRemoved() {
        Fixture().use { fixture ->
            val retention = fixture.retention()
            retention.finishIncoming(retention.beginIncoming().path)
            val directory = File(fixture.cache, "app-update/install")
            val userFile = File(fixture.root, "user-download.apk").apply { writeText("important") }
            val malformed = File(directory, "keep-user.apk").apply { writeText("important") }
            val link = File(directory, "${UUID.randomUUID()}.apk")
            Os.symlink(userFile.path, link.path)
            val nested = File(directory, "${UUID.randomUUID()}.apk").apply { mkdirs() }
            val child = File(nested, "backup.apk").apply { writeText("important") }
            assertThrows(IllegalArgumentException::class.java) { retention.candidate(link.path) }
            assertThrows(IllegalArgumentException::class.java) { retention.releaseCandidate(malformed) }
            val result = retention.maintain(clear = true)
            assertTrue(result.skippedFiles >= 3)
            assertTrue(userFile.exists())
            assertTrue(malformed.exists())
            assertTrue(link.exists())
            assertTrue(child.exists())
        }
    }

    @Test fun pureScanLeavesMissingRootsMissingAndRejectsDirectoryAliases() {
        Fixture().use { fixture ->
            val empty = fixture.retention().storageInfo()
            assertEquals(0L, empty.incomingBytes + empty.installBytes + empty.legacyBytes)
            assertFalse(File(fixture.cache, "app-update").exists())
            assertFalse(File(fixture.files, "app-update").exists())
            val outside = File(fixture.root, "outside").apply { mkdirs() }
            val victim = File(outside, "${UUID.randomUUID()}.apk").apply { writeText("preserve") }
            Os.symlink(outside.path, File(fixture.cache, "app-update").path)
            val aliased = fixture.retention()
            assertTrue(aliased.maintain(clear = true).skippedFiles > 0)
            assertTrue(victim.exists())
            assertThrows(IllegalArgumentException::class.java) { aliased.beginIncoming() }
        }
    }

    @Test fun anotherActivityCannotReapAStillStreamingIncomingLease() {
        Fixture().use { fixture ->
            val original = fixture.retention()
            val incoming = original.beginIncoming().apply { writeText("still streaming") }
            original.close()
            val replacement = fixture.retention()
            replacement.maintain(clear = true)
            assertTrue(incoming.exists())
            original.finishIncoming(incoming.path)
            assertFalse(incoming.exists())
        }
    }

    @Test fun preparedHandoffCanBeReopenedAfterProcessDeathWithoutDeletingBytes() {
        Fixture().use { fixture ->
            val original = fixture.retention()
            val candidate = fixture.candidate(original)
            original.beginHandoff(candidate)
            original.close()
            val restarted = fixture.retention()
            val restored = requireNotNull(restarted.pendingCandidate())
            restarted.beginHandoff(restored)
            assertTrue(restored.exists())
            assertFalse(restarted.releaseCandidate(restored))
            restarted.finishHandoff()
            assertTrue(restored.exists())
            assertTrue(restarted.releaseCandidate(restored))
        }
    }

    @Test fun disposedPageKeepsInstallerBytesOnlyUntilInstallerReturns() {
        Fixture().use { fixture ->
            val retention = fixture.retention()
            val candidate = fixture.candidate(retention)
            assertTrue(retention.beginHandoff(candidate))
            assertFalse(retention.beginHandoff(candidate))
            assertFalse(retention.releaseCandidate(candidate, relinquish = true))
            assertTrue(candidate.exists())
            retention.finishHandoff()
            assertFalse(candidate.exists())
        }
    }

    @Test fun malformedOldLeaseProtectsOldPathsButNotFreshCandidates() {
        Fixture().use { fixture ->
            val legacyRoot = File(fixture.files, "app-update").apply { mkdirs() }
            File(legacyRoot, "installer-lease").writeText("not-a-uuid")
            val install = File(fixture.cache, "app-update/install").canonicalFile.apply { mkdirs() }
            val old = File(install, "${UUID.randomUUID()}.apk").apply {
                writeText("$packageName|174|$signer")
            }
            val retention = fixture.retention()
            val fresh = fixture.candidate(retention)
            assertTrue(retention.releaseCandidate(fresh))
            assertFalse(fresh.exists())
            assertFalse(retention.releaseCandidate(old))
            retention.maintain(clear = true)
            assertTrue(old.exists())
        }
    }

    @Test fun actualSignedInstalledApkIsReapedFromLegacyAndNewStaging() {
        Fixture().use { fixture ->
            val context = fixture.context
            val apk = File(context.applicationInfo.sourceDir)
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            @Suppress("DEPRECATION")
            val version = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            val installed = AppUpdateRetention.Identity(context.packageName, version,
                AppUpdateHost.verifiedSigner(apk, Build.VERSION.SDK_INT))
            fun retention() = AppUpdateRetention(fixture.cache, fixture.files, installed = { installed }, inspect = { file ->
                val parsed = requireNotNull(context.packageManager.getPackageArchiveInfo(file.path, 0))
                @Suppress("DEPRECATION")
                val code = if (Build.VERSION.SDK_INT >= 28) parsed.longVersionCode else parsed.versionCode.toLong()
                AppUpdateRetention.Identity(parsed.packageName, code, AppUpdateHost.verifiedSigner(file, Build.VERSION.SDK_INT))
            })
            val running = retention()
            val incoming = running.beginIncoming()
            apk.copyTo(incoming, overwrite = true)
            val candidate = running.copyIncoming(incoming.path) { source, target -> source.copyTo(target, overwrite = true) }
            val legacy = File(fixture.files, "app-update/install").apply { mkdirs() }
            val legacyCopy = File(legacy, "${UUID.randomUUID()}.apk")
            apk.copyTo(legacyCopy)
            val restarted = retention()
            restarted.maintain()
            assertFalse(candidate.exists())
            assertFalse(legacyCopy.exists())
        }
    }
}
