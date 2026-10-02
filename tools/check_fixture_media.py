"""Offline metadata and dynamic-frame check for the bundled video fixture."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import argparse
import json
from pathlib import Path
from typing import Any

import cv2

# 解码帧数上限：夹具是毫秒级的小文件，这个上限只为挡住误传进来的
# 超大视频把检查变成全片转码，不参与正常判定。
_MAX_DECODED_FRAMES = 20000


@dataclass(frozen=True)
class FixtureMediaSummary:
    path: str
    frames: int
    fps: float
    duration_seconds: float
    width: int
    height: int
    sampled_frame_delta: float
    dynamic: bool

    def to_json_dict(self) -> dict[str, Any]:
        """Stable JSON shape: file name only, never the absolute path.

        The summary may be pasted into checkpoints and logs; an absolute
        path would leak the machine layout and make runs incomparable.
        """

        data = asdict(self)
        data["file"] = Path(data.pop("path")).name
        return data


def inspect_media(path: str | Path, *, sample_count: int = 12) -> FixtureMediaSummary:
    media_path = Path(path)
    capture = cv2.VideoCapture(str(media_path))
    if not capture.isOpened():
        raise RuntimeError(f"cannot open video fixture: {media_path}")
    try:
        metadata_frames = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
        # 逐帧解码拿到真实可读帧数：截断文件的元数据仍会声称完整时长，
        # 只有实际解码出来的帧数不会撒谎（截断文件会因时长骤减被拒）。
        stride = max(metadata_frames // max(sample_count, 2), 1)
        decoded = 0
        deltas: list[float] = []
        previous: Any = None
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            decoded += 1
            if len(deltas) < sample_count and decoded % stride == 0:
                if previous is not None:
                    delta = cv2.absdiff(frame, previous)
                    deltas.append(float(delta.mean()))
                previous = frame
            if decoded >= _MAX_DECODED_FRAMES:
                break
    finally:
        capture.release()
    sampled_delta = max(deltas, default=0.0)
    return FixtureMediaSummary(
        path=str(media_path),
        frames=decoded,
        fps=fps,
        duration_seconds=decoded / fps if fps > 0 else 0.0,
        width=width,
        height=height,
        sampled_frame_delta=sampled_delta,
        dynamic=sampled_delta > 0.5,
    )


def validate_fixture(summary: FixtureMediaSummary) -> None:
    # `not (fps > 0)` 同时挡住 0 和 NaN（部分损坏文件会让 OpenCV 回 NaN）。
    if summary.frames <= 0 or not (summary.fps > 0):
        raise AssertionError("fixture has no decodable frames or frame rate")
    if summary.duration_seconds < 5:
        raise AssertionError(f"fixture is unexpectedly short: {summary.duration_seconds:.2f}s")
    if not summary.dynamic:
        raise AssertionError("sampled fixture frames do not change")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "path",
        nargs="?",
        default=str(Path(__file__).with_name("fixture_media") / "sample.mp4"),
    )
    args = parser.parse_args()
    summary = inspect_media(args.path)
    validate_fixture(summary)
    print(json.dumps(summary.to_json_dict(), ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
