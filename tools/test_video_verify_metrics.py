import unittest

from tools.video_verify_metrics import (
    LogSummary,
    PlayerStateSample,
    assert_dynamic_playback,
    parse_logcat,
    pixel_summary,
    sanitize_url,
)


def state_line(position: int, url: str | None = None) -> str:
    suffix = f" url={url}" if url else ""
    return (
        f"D/TriomiNativeVideo: state{suffix} prepared=true playing=true "
        f"position={position} duration=30023"
    )


def dynamic_states(*positions: int, url: str | None = None) -> LogSummary:
    prepared = "D/TriomiNativeVideo: prepared duration=30023"
    return parse_logcat(
        [prepared] + [state_line(position, url) for position in positions]
    )


def good_pixels(changed: float = 0.08, frames: int = 4) -> list[dict[str, float | None]]:
    return [{"non_black": 0.86, "delta": 3.4, "changed": changed} for _ in range(frames)]


class VideoVerifyMetricsTest(unittest.TestCase):
    def test_parses_prepared_state_and_ignores_unrelated_error(self) -> None:
        summary = parse_logcat(
            [
                "D/TriomiNativeVideo: prepared duration=30023 url=http://10.0.2.2:8123/video/sample.mp4",
                "D/TriomiNativeVideo: state url=http://10.0.2.2:8123/video/sample.mp4?token=secret prepared=true playing=true position=1000 duration=30023",
                "D/Other: error what=-1 extra=-2",
            ]
        )
        self.assertEqual(summary.prepared[0].duration_ms, 30023)
        self.assertEqual(summary.states[0].position_ms, 1000)
        self.assertEqual(summary.errors, ())
        self.assertEqual(summary.progressed_ms, 0)

    def test_summarises_rows_and_accepts_dynamic_run(self) -> None:
        rows = [
            {"non_black": 0.85, "delta": None, "changed": None},
            {"non_black": 0.86, "delta": 3.4, "changed": 0.08},
            {"non_black": 0.85, "delta": 4.1, "changed": 0.1},
        ]
        summary = parse_logcat(
            [
                "D/TriomiNativeVideo: prepared duration=30023",
                "D/TriomiNativeVideo: state prepared=true playing=true position=1000 duration=30023",
                "D/TriomiNativeVideo: state prepared=true playing=true position=1800 duration=30023",
            ]
        )
        stats = pixel_summary(rows)
        self.assertEqual(stats["frames"], 3)
        self.assertAlmostEqual(stats["changed_max"], 0.1)
        assert_dynamic_playback(summary, rows)

    def test_dynamic_assertion_rejects_static_black_capture(self) -> None:
        summary = dynamic_states(1000, 1100)
        with self.assertRaises(AssertionError):
            assert_dynamic_playback(summary, [{"non_black": 0.0, "changed": 0.0}])

    # ------------------------------------------------------------ G1/D11 补充

    def test_empty_log_is_rejected_with_prepared_message(self) -> None:
        summary = parse_logcat([])
        self.assertEqual(summary.prepared, ())
        self.assertEqual(summary.states, ())
        self.assertEqual(summary.errors, ())
        self.assertEqual(summary.progressed_ms, 0)
        with self.assertRaisesRegex(AssertionError, "never emitted prepared"):
            assert_dynamic_playback(summary, good_pixels())

    def test_query_and_fragment_never_reach_parsed_output(self) -> None:
        summary = parse_logcat(
            [
                "D/TriomiNativeVideo: prepared duration=30023 url=https://host/v.mp4?token=super-secret#frag",
                state_line(1000, "https://host/v.mp4?sign=abc&token=super-secret"),
                state_line(1800, "https://host/v.mp4?sign=abc&token=super-secret"),
            ]
        )
        rendered = repr(summary)
        self.assertNotIn("super-secret", rendered)
        self.assertNotIn("?", rendered)
        self.assertEqual(summary.prepared[0].url, "https://host/v.mp4")
        self.assertEqual(summary.states[0].url, "https://host/v.mp4")

    def test_sanitize_url_keeps_plain_values(self) -> None:
        self.assertIsNone(sanitize_url(None))
        self.assertEqual(sanitize_url("https://h/p.mp4"), "https://h/p.mp4")
        self.assertIsNone(sanitize_url("?token=x"))

    def test_multiple_prepared_events_are_all_kept(self) -> None:
        # Surface 重建 / 换线路都会再次 prepared；解析不能丢事件。
        summary = parse_logcat(
            [
                "D/TriomiNativeVideo: prepared duration=30023 url=https://h/a.mp4",
                "D/TriomiNativeVideo: prepared duration=120000 url=https://h/b.mp4",
            ]
        )
        self.assertEqual(len(summary.prepared), 2)
        self.assertEqual(summary.prepared[0].duration_ms, 30023)
        self.assertEqual(summary.prepared[1].duration_ms, 120000)
        # 多 prepared 本身不是失败：其余证据齐全就应通过。
        assert_dynamic_playback(
            dynamic_states(1000, 3000), good_pixels()
        )

    def test_position_regression_does_not_count_as_progress(self) -> None:
        # 回退（如重建后 seek 回旧点）不能虚报推进量。
        summary = dynamic_states(5000, 4000, 4100)
        self.assertEqual(summary.progressed_ms, 100)

    def test_position_reset_across_line_switch_counts_new_line_only(self) -> None:
        # 换线路：旧片尾 29000 → 新片头 100。旧位置不是新线路的播放证据。
        summary = dynamic_states(29000, 100, 700, 1300)
        self.assertEqual(summary.progressed_ms, 1200)

    def test_old_line_progress_cannot_hide_frozen_new_line(self) -> None:
        summary = parse_logcat(
            [
                "D/TriomiNativeVideo: prepared duration=30023 url=https://h/a.mp4",
                state_line(1000, "https://h/a.mp4"),
                state_line(5000, "https://h/a.mp4"),
                "D/TriomiNativeVideo: prepared duration=30023 url=https://h/b.mp4",
                state_line(100, "https://h/b.mp4"),
                state_line(100, "https://h/b.mp4"),
            ]
        )
        self.assertEqual(summary.progressed_ms, 0)
        with self.assertRaisesRegex(AssertionError, "progressed only 0 ms"):
            assert_dynamic_playback(summary, good_pixels())

    def test_frozen_after_first_frame_is_rejected(self) -> None:
        # 只有首帧动了，之后相邻帧差全为 0：均值判定应拒绝，单点尖峰不能蒙混。
        summary = dynamic_states(1000, 1200, 1400, 1600)
        rows = [
            {"non_black": 0.86, "delta": 5.0, "changed": 0.10},
            {"non_black": 0.86, "delta": 0.0, "changed": 0.0},
            {"non_black": 0.86, "delta": 0.0, "changed": 0.0},
        ]
        with self.assertRaisesRegex(AssertionError, "did not change"):
            assert_dynamic_playback(summary, rows)

    def test_all_none_changed_measurement_is_rejected(self) -> None:
        summary = dynamic_states(1000, 2000)
        rows = [{"non_black": 0.86, "delta": None, "changed": None}] * 3
        with self.assertRaisesRegex(AssertionError, "no changed measurement"):
            assert_dynamic_playback(summary, rows)

    def test_all_none_non_black_measurement_is_rejected(self) -> None:
        summary = dynamic_states(1000, 2000)
        rows = [{"non_black": None, "delta": 3.0, "changed": 0.08}] * 3
        with self.assertRaisesRegex(AssertionError, "no non_black measurement"):
            assert_dynamic_playback(summary, rows)

    def test_native_error_rejects_even_with_good_pixels(self) -> None:
        summary = parse_logcat(
            [
                "D/TriomiNativeVideo: prepared duration=30023",
                state_line(1000),
                state_line(2000),
                "E/TriomiNativeVideo: error what=-1 extra=0 position=2000 duration=30023",
            ]
        )
        with self.assertRaisesRegex(AssertionError, "emitted errors"):
            assert_dynamic_playback(summary, good_pixels())

    def test_only_timeline_progress_without_pixel_change_is_rejected(self) -> None:
        # 时间轴推进不等于画面在动：像素证据缺失必须失败（P2 关注点）。
        summary = dynamic_states(1000, 3000)
        with self.assertRaisesRegex(AssertionError, "did not change"):
            assert_dynamic_playback(
                summary,
                [{"non_black": 0.86, "delta": None, "changed": 0.0}] * 2,
            )

    def test_same_url_reprepare_discards_previous_progress(self) -> None:
        for boundary in (
            "prepared duration=30023 url=https://h/a.mp4",
            "setUrl url=https://h/a.mp4 surface=true",
            "surface destroyed prepared=true position=5000",
        ):
            with self.subTest(boundary=boundary):
                summary = parse_logcat([
                    "D/TriomiNativeVideo: prepared duration=30023",
                    state_line(1000), state_line(5000),
                    f"D/TriomiNativeVideo: {boundary}",
                    state_line(5000), state_line(5000),
                ])
                self.assertEqual(summary.progressed_ms, 0)
                with self.assertRaisesRegex(AssertionError, "progressed only 0 ms"):
                    assert_dynamic_playback(summary, good_pixels())

    def test_unrelated_tag_mentioning_native_player_is_ignored(self) -> None:
        summary = parse_logcat([
            "D/Other: TriomiNativeVideo prepared duration=30023",
            "D/Other: TriomiNativeVideo state prepared=true playing=true position=1000 duration=30023",
        ])
        self.assertEqual(summary.prepared, ())
        self.assertEqual(summary.states, ())

    def test_threadtime_tag_is_supported(self) -> None:
        summary = parse_logcat(["10-01 21:00:00.000 123 456 D TriomiNativeVideo: prepared duration=30023"])
        self.assertEqual(len(summary.prepared), 1)

    def test_small_seek_back_discards_earlier_progress(self) -> None:
        self.assertEqual(dynamic_states(1000, 2000, 1800, 1800).progressed_ms, 0)

    def test_paused_position_changes_are_not_playback(self) -> None:
        summary = parse_logcat([
            "D/TriomiNativeVideo: prepared duration=30023",
            state_line(1000).replace("playing=true", "playing=false"),
            state_line(5000).replace("playing=true", "playing=false"),
        ])
        self.assertEqual(summary.progressed_ms, 0)

    def test_nonfinite_or_out_of_range_pixels_are_rejected(self) -> None:
        for key in ("non_black", "changed"):
            for value in (float("nan"), float("inf"), -0.1, 1.1):
                rows = good_pixels()
                rows[0][key] = value
                with self.subTest(key=key, value=value):
                    with self.assertRaisesRegex(AssertionError, "invalid pixel"):
                        assert_dynamic_playback(dynamic_states(1000, 2000), rows)

    def test_url_userinfo_is_removed(self) -> None:
        self.assertEqual(sanitize_url("https://user:password@h/p.mp4?token=x"), "https://h/p.mp4")


if __name__ == "__main__":
    unittest.main()
