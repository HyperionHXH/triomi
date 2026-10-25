package io.github.hyperionhxh.triomi

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.source.SinglePeriodTimeline
import androidx.media3.exoplayer.upstream.Allocation
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the same real Media3 LoadControl factory installed in the view. */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class PlaybackBufferPolicyTest {
    @Test fun budgetReservesMostOfTheHeapAndNeverExceeds128MiB() {
        assertEquals(16 * 1024 * 1024, PlaybackBufferPolicy.memoryBudgetBytes(128L * 1024 * 1024))
        assertEquals(32 * 1024 * 1024, PlaybackBufferPolicy.memoryBudgetBytes(256L * 1024 * 1024))
        assertEquals(128 * 1024 * 1024, PlaybackBufferPolicy.memoryBudgetBytes(4L * 1024 * 1024 * 1024))
    }

    @Test fun loadsBeyondShortLookaheadStopsAtByteBudgetAndRefillsWithoutWaitingForDepletion() {
        for (scheme in listOf("https", "file")) {
            for (speed in listOf(.5f, 1f, 3f)) {
                // Keep the test's actual allocations small, using the production
                // heap-relative budget calculation rather than a fake allocator.
                val heapBytes = 8L * 1024 * 1024
                val control = PlaybackBufferPolicy.createLoadControl(heapBytes)
                val id = PlayerId.UNSET
                control.onPrepared(id)
                val allocator = control.getAllocator(id)
                val allocations = ArrayList<Allocation>()
                val timeline = SinglePeriodTimeline(1_440_000_000L, true, false, false, null,
                    MediaItem.fromUri("$scheme:///episode.mp4"))
                fun parameters(bufferedUs: Long, rebuffering: Boolean = false) = LoadControl.Parameters(
                    id, timeline, MediaPeriodId(timeline.getUidOfPeriod(0)), 0L,
                    bufferedUs, speed, true, rebuffering, C.TIME_UNSET, C.TIME_UNSET)
                try {
                    assertEquals(0L, control.getBackBufferDurationUs(id))
                    assertFalse(control.retainBackBufferFromKeyframe(id))
                    assertTrue("Ten minutes ahead must not hit a short time horizon",
                        control.shouldContinueLoading(parameters(600_000_000L)))
                    assertFalse("Whole-episode preloading must not delay initial playback",
                        control.shouldStartPlayback(parameters(1_000L)))
                    assertTrue(control.shouldStartPlayback(parameters((1_000_000L * speed).toLong())))
                    val rebufferUs = if (scheme == "file") 1_000_000L else 2_000_000L
                    assertFalse(control.shouldStartPlayback(parameters((rebufferUs / 2 * speed).toLong(), true)))
                    assertTrue(control.shouldStartPlayback(parameters((rebufferUs * speed).toLong(), true)))
                    while (allocator.totalBytesAllocated < PlaybackBufferPolicy.memoryBudgetBytes(heapBytes)) {
                        allocations.add(allocator.allocate())
                    }
                    assertFalse("Memory must win over the episode-long time horizon",
                        control.shouldContinueLoading(parameters(600_000_000L)))
                    allocator.release(allocations.removeAt(allocations.lastIndex))
                    assertTrue("Refill as memory frees, even with ten minutes still buffered",
                        control.shouldContinueLoading(parameters(599_000_000L)))
                } finally {
                    allocations.forEach { allocator.release(it) }
                    assertEquals("Released packets must not remain allocated", 0, allocator.totalBytesAllocated)
                    control.onReleased(id)
                }
            }
        }
    }
}
