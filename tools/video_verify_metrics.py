"""Pure Python data layer for playback verification.

The device script collects logcat and PNG files. This module only parses and
summarises them so the evidence can be replayed offline. Unit tests do not
replace Android device acceptance.

Contract notes (G1/D11 review):

- Only ``TriomiNativeVideo`` lines are parsed; everything else in logcat is
  noise (including unrelated ``error what=`` lines from other tags).
- URLs are sanitised to ``scheme://host/path`` before they enter any
  dataclass, so query strings (which may carry tokens) never reach the
  summaries. Kotlin already logs sanitised URLs; this is the second layer.
- ``progressed_ms`` is the sum of positive position deltas between
  consecutive samples. A position regression (surface rebuild seek-back) or
  a reset (line switch restarts at 0) therefore cannot fake progress: the
  new line must advance on its own to count.
- ``assert_dynamic_playback`` requires prepared, zero native errors,
  timeline progress, non-black frames AND frame-to-frame change. The pixel
  checks use the mean over samples so a frozen-after-first-frame capture
  (one early change, then 0.0) is rejected, not masked by a single spike.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from statistics import mean
from typing import Iterable, Mapping, Sequence


_PREPARED = re.compile(
    r"prepared duration=(?P<duration>\d+)(?:\s+url=(?P<url>\S+))?"
)
_STATE = re.compile(
    r"state(?:\s+url=(?P<url>\S+))?\s+prepared=(?P<prepared>true|false)"
    r"\s+playing=(?P<playing>true|false)\s+position=(?P<position>\d+)"
    r"\s+duration=(?P<duration>\d+)"
)
_ERROR = re.compile(r"error what=(?P<what>-?\d+) extra=(?P<extra>-?\d+)")


def sanitize_url(url: str | None) -> str | None:
    """Strip query and fragment so tokens cannot leak into parsed output."""

    if url is None:
        return None
    cleaned = url.split("?", 1)[0].split("#", 1)[0]
    return cleaned or None


@dataclass(frozen=True)
class PreparedEvent:
    duration_ms: int
    url: str | None = None


@dataclass(frozen=True)
class PlayerStateSample:
    position_ms: int
    duration_ms: int
    prepared: bool
    playing: bool
    url: str | None = None


@dataclass(frozen=True)
class PlayerError:
    what: int
    extra: int


@dataclass(frozen=True)
class LogSummary:
    prepared: tuple[PreparedEvent, ...]
    states: tuple[PlayerStateSample, ...]
    errors: tuple[PlayerError, ...]

    @property
    def progressed_ms(self) -> int:
        """Sum of positive position deltas between consecutive samples.

        Regressions and resets contribute nothing, so a capture that only
        shows the tail of one video and the head of the next does not look
        like continuous playback.
        """

        progress = 0
        for previous, current in zip(self.states, self.states[1:]):
            delta = current.position_ms - previous.position_ms
            if delta > 0:
                progress += delta
        return progress


def parse_logcat(lines: Iterable[str]) -> LogSummary:
    """Parse TriomiNativeVideo lines and ignore unrelated logcat text."""

    prepared: list[PreparedEvent] = []
    states: list[PlayerStateSample] = []
    errors: list[PlayerError] = []
    for line in lines:
        if "TriomiNativeVideo" not in line:
            continue
        match = _PREPARED.search(line)
        if match:
            prepared.append(
                PreparedEvent(
                    duration_ms=int(match.group("duration")),
                    url=sanitize_url(match.group("url")),
                )
            )
            continue
        match = _STATE.search(line)
        if match:
            states.append(
                PlayerStateSample(
                    position_ms=int(match.group("position")),
                    duration_ms=int(match.group("duration")),
                    prepared=match.group("prepared") == "true",
                    playing=match.group("playing") == "true",
                    url=sanitize_url(match.group("url")),
                )
            )
            continue
        match = _ERROR.search(line)
        if match:
            errors.append(
                PlayerError(
                    what=int(match.group("what")), extra=int(match.group("extra"))
                )
            )
    return LogSummary(tuple(prepared), tuple(states), tuple(errors))


def pixel_summary(rows: Iterable[Mapping[str, float | None]]) -> dict[str, float | int]:
    """Summarise rows with non_black, delta and changed measurements."""

    rows_list = list(rows)
    values: dict[str, list[float]] = {"non_black": [], "delta": [], "changed": []}
    for row in rows_list:
        for key in values:
            value = row.get(key)
            if value is not None:
                values[key].append(float(value))
    result: dict[str, float | int] = {"frames": len(rows_list)}
    for key, entries in values.items():
        if entries:
            result[f"{key}_min"] = min(entries)
            result[f"{key}_max"] = max(entries)
            result[f"{key}_mean"] = mean(entries)
    return result


def assert_dynamic_playback(
    summary: LogSummary,
    pixels: Sequence[Mapping[str, float | None]],
    *,
    min_progress_ms: int = 500,
    min_non_black: float = 0.05,
    min_changed: float = 0.001,
    min_changed_ratio: float = 0.5,
) -> None:
    """Raise AssertionError when a capture is not dynamically playable."""

    if not summary.prepared:
        raise AssertionError("native player never emitted prepared")
    if summary.errors:
        raise AssertionError(f"native player emitted errors: {summary.errors}")
    if summary.progressed_ms < min_progress_ms:
        raise AssertionError(f"position progressed only {summary.progressed_ms} ms")
    pixel_rows = list(pixels)
    non_black = [
        float(row["non_black"])
        for row in pixel_rows
        if row.get("non_black") is not None
    ]
    changed = [
        float(row["changed"])
        for row in pixel_rows
        if row.get("changed") is not None
    ]
    if not non_black:
        raise AssertionError("capture has no non_black measurement")
    if mean(non_black) < min_non_black:
        raise AssertionError("video viewport is effectively black")
    if not changed:
        raise AssertionError("capture has no changed measurement")
    if mean(changed) < min_changed:
        raise AssertionError("adjacent frames did not change")
    # 单点尖峰不能当动态证据：至少一半的相邻帧采样要真的在变，
    # 否则「首帧之后冻结」的截图（一个早期变化 + 全 0）会被均值放过。
    changing = sum(1 for value in changed if value >= min_changed)
    if changing / len(changed) < min_changed_ratio:
        raise AssertionError(
            "adjacent frames did not change (static after first frame?)"
        )
