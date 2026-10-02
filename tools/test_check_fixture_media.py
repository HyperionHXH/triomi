import json
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

from tools.check_fixture_media import (
    FixtureMediaSummary,
    inspect_media,
    validate_fixture,
)

SAMPLE = Path(__file__).with_name("fixture_media") / "sample.mp4"


def write_video(
    path: Path,
    *,
    frames: int,
    moving: bool = True,
    fps: int = 24,
    size: tuple[int, int] = (64, 48),
) -> None:
    """Write a tiny AVI (MJPG) so tests never touch the real fixture."""

    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"MJPG"), fps, size)
    try:
        for index in range(frames):
            frame = np.zeros((size[1], size[0], 3), dtype=np.uint8)
            if moving:
                x = (index * 7) % (size[0] - 8)
                frame[:, x : x + 8] = 255
            writer.write(frame)
    finally:
        writer.release()


class FixtureMediaTest(unittest.TestCase):
    def test_bundled_sample_has_duration_and_dynamic_frames(self) -> None:
        summary = inspect_media(SAMPLE)
        validate_fixture(summary)
        self.assertGreaterEqual(summary.frames, 100)
        self.assertGreaterEqual(summary.fps, 20)
        self.assertGreaterEqual(summary.duration_seconds, 5)
        self.assertTrue(summary.dynamic)

    def test_json_shape_is_stable_and_path_free(self) -> None:
        summary = inspect_media(SAMPLE)
        data = summary.to_json_dict()
        self.assertEqual(
            sorted(data),
            [
                "duration_seconds",
                "dynamic",
                "file",
                "fps",
                "frames",
                "height",
                "sampled_frame_delta",
                "width",
            ],
        )
        self.assertEqual(data["file"], "sample.mp4")
        rendered = json.dumps(data, sort_keys=True)
        self.assertNotIn(str(SAMPLE.resolve()), rendered)
        self.assertNotIn("\\", rendered, msg="JSON 里不应出现绝对路径")

    # ------------------------------------------------------------ G2/D12 补充

    def test_unopenable_file_raises_runtime_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            garbage = Path(tmp) / "garbage.mp4"
            garbage.write_bytes(b"not a video at all" * 32)
            with self.assertRaises(RuntimeError):
                inspect_media(garbage)

    def test_truncated_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            full = Path(tmp) / "full.avi"
            write_video(full, frames=130)
            truncated = Path(tmp) / "truncated.avi"
            raw = full.read_bytes()
            truncated.write_bytes(raw[: len(raw) // 3])

            # 要么打不开（RuntimeError），要么解码出的真实时长骤减被拒；
            # 元数据声称的完整时长不能当证据。
            with self.assertRaises((RuntimeError, AssertionError)):
                summary = inspect_media(truncated)
                validate_fixture(summary)

    def test_zero_fps_or_zero_frames_summary_is_rejected(self) -> None:
        base = dict(
            path="x.avi",
            frames=720,
            fps=24.0,
            duration_seconds=30.0,
            width=640,
            height=360,
            sampled_frame_delta=29.3,
            dynamic=True,
        )
        validate_fixture(FixtureMediaSummary(**base))
        with self.assertRaisesRegex(AssertionError, "no decodable frames"):
            validate_fixture(FixtureMediaSummary(**{**base, "fps": 0.0}))
        with self.assertRaisesRegex(AssertionError, "no decodable frames"):
            validate_fixture(FixtureMediaSummary(**{**base, "frames": 0}))
        # OpenCV 对部分损坏文件会回 NaN 帧率，也要被拒。
        with self.assertRaisesRegex(AssertionError, "no decodable frames"):
            validate_fixture(FixtureMediaSummary(**{**base, "fps": float("nan")}))

    def test_short_video_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            short = Path(tmp) / "short.avi"
            write_video(short, frames=24)  # 24fps × 24 帧 = 1s
            summary = inspect_media(short)
            with self.assertRaisesRegex(AssertionError, "unexpectedly short"):
                validate_fixture(summary)

    def test_static_video_is_rejected_as_not_dynamic(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            static = Path(tmp) / "static.avi"
            write_video(static, frames=130, moving=False)  # ≈5.4s 全黑
            summary = inspect_media(static)
            self.assertFalse(summary.dynamic)
            with self.assertRaisesRegex(AssertionError, "do not change"):
                validate_fixture(summary)

    def test_moving_temp_video_passes_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            moving = Path(tmp) / "moving.avi"
            write_video(moving, frames=130)
            summary = inspect_media(moving)
            validate_fixture(summary)
            self.assertTrue(summary.dynamic)
            self.assertGreater(summary.sampled_frame_delta, 0.5)


if __name__ == "__main__":
    unittest.main()
