"""Scan for fragile UI locators and stale work-order assertions.

Background (P1/D14): the old out-of-repo device script navigated by "the 2nd
tab" and broke as soon as the UI copy changed. This scanner pins down the two
failure modes so they cannot sneak back in:

- ``fixed_index_nav`` / ``positional_label`` (severity ``error``): literal
  element indexes or positional labels ("第 N 个…") inside navigation/tap
  context. Ordinary loops use variables, not literals, and stay unflagged.
  These are the only findings that make the process exit non-zero.
- ``stale_task`` (severity ``warning``): unchecked T1–T7 / D1–D5 checkboxes in
  the current-truth docs. Those work orders are done; an unchecked box means
  the document drifted (informational only, does not fail the run).
- ``historical_doc`` / ``historical_copy`` (severity ``info``): files that are
  declared historical are reported, never "fixed" — history stays.

Usage::

    python tools/ui_doc_drift_scan.py            # human-readable
    python tools/ui_doc_drift_scan.py --json     # machine-readable

Exit code is 1 only when a genuine fragile locator is found.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
import argparse
import json
from pathlib import Path
import re
import sys
from typing import Sequence

# 导航/点击上下文：只有同时命中上下文与固定下标才算脆弱定位，
# 避免把解析层单测里的 items[1] 这类数据断言误报成 UI 导航。
_CONTEXT_RE = re.compile(
    r"\b(?:tap|click|press|swipe|tabs?|chips?|drawer|navbar|navigationbar"
    r"|bottomnav|nav|menu)\b|标签|导航|菜单",
    re.IGNORECASE,
)
_COLLECTION_INDEX_RE = re.compile(
    r"\b(?:tabs?|chips?|items?|rows?|children|elements?|els|boxes|labels?"
    r"|views?|widgets?|destinations?|buttons?|cards?|tiles?|nodes?|entries"
    r"|sources?)\w*\[(\d+)\]"
)
_POSITIONAL_LABEL_RE = re.compile(
    r"(?:find|tap|click|press|wait_?for|expect)[\w.]*\s*\(\s*['\"]"
    r"[^'\"]*第\s*\d+\s*[个项页条步张层]"
)
_SUPPRESS_MARKER = "drift-scan: allow"

# 旧工作单编号：T8 是 README/CI 收尾、D8+ 是后来的纯代码任务，都不在
# 「旧待开发」范围里；\b 保证 D1 不会命中 D11。
_STALE_TASK_RE = re.compile(r"-\s*\[ \].*\b(?:T[1-7]|D[1-5])\b")

# 历史声明必须是「本文件是历史副本/记录」这类自指，或者标题里带
# （历史记录）；仅引用到「历史」二字的当前文档不能算。
_HISTORICAL_SELF_RE = re.compile(
    r"本文件[^。\n]{0,30}历史|（历史记录）|历史副本"
)

_CURRENT_DOCS = (
    "docs/AFTER_M5_PLAN.md",
    "docs/handoff/README.md",
    "docs/PROJECT_SPEC.md",
)
_DEPRECATION_MARKER = "不作为当前执行状态"

_CODE_GLOBS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("tools", ("*.py",)),
    ("test", ("*.dart",)),
    ("lib", ("*.dart",)),
)


@dataclass(frozen=True)
class Finding:
    severity: str  # error | warning | info
    kind: str
    file: str  # repo 相对路径（posix 风格），输出里不带绝对路径
    line: int
    message: str

    def to_dict(self) -> dict[str, str | int]:
        return asdict(self)


def _is_suppressed(line: str) -> bool:
    return _SUPPRESS_MARKER in line


def scan_line(line: str) -> list[tuple[str, str]]:
    """Return (kind, message) pairs for one line of code."""

    if _is_suppressed(line):
        return []
    findings: list[tuple[str, str]] = []
    if _CONTEXT_RE.search(line):
        for match in _COLLECTION_INDEX_RE.finditer(line):
            index = int(match.group(1))
            if index >= 1:
                findings.append(
                    (
                        "fixed_index_nav",
                        f"导航上下文里用固定下标 {match.group(0)}，"
                        "UI 顺序一变就会点错控件；改用语义文本查找",
                    )
                )
    if _POSITIONAL_LABEL_RE.search(line):
        findings.append(
            (
                "positional_label",
                "查找控件用了「第 N 个…」式位置标签，文案一变就断链；"
                "改用不随顺序改变的语义文本",
            )
        )
    return findings


def _is_historical_doc(text: str) -> bool:
    head = "\n".join(text.splitlines()[:10])
    return _HISTORICAL_SELF_RE.search(head) is not None


def _code_files(root: Path) -> list[Path]:
    files: list[Path] = []
    self_name = Path(__file__).name
    for base, patterns in _CODE_GLOBS:
        directory = root / base
        if not directory.is_dir():
            continue
        for pattern in patterns:
            for path in sorted(directory.rglob(pattern)):
                if path.name == self_name:
                    continue  # 扫描器自身按定义含模式示例，不自举报
                if path.name.startswith("test_"):
                    continue  # Python 单测不是设备脚本；Dart 测试保留
                if path.suffix == ".dart" and path.name.endswith(".g.dart"):
                    continue  # 生成代码
                if "__pycache__" in path.parts:
                    continue
                files.append(path)
    return files


def scan_code(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in _code_files(root):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            findings.append(
                Finding("warning", "unreadable_file", _rel(root, path), 0, str(error))
            )
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            for kind, message in scan_line(line):
                findings.append(
                    Finding("error", kind, _rel(root, path), number, message)
                )
    return findings


def scan_docs(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for rel in _CURRENT_DOCS:
        path = root / rel
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if _is_historical_doc(text):
            findings.append(
                Finding(
                    "info",
                    "historical_doc",
                    rel,
                    0,
                    "文件头部声明为历史记录，跳过旧待办检查",
                )
            )
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if _STALE_TASK_RE.search(line) and not _is_suppressed(line):
                snippet = line.strip()
                if len(snippet) > 80:
                    snippet = snippet[:80] + "…"
                findings.append(
                    Finding(
                        "warning",
                        "stale_task",
                        rel,
                        number,
                        "当前文档残留未勾选的旧工作单条目（T1-T7/D1-D5 均已"
                        f"交付）：{snippet}",
                    )
                )

    # 双份 PROJECT_SPEC：根目录副本（仓库外）只能作历史记录，不能静默覆盖。
    repo_spec = root / "docs" / "PROJECT_SPEC.md"
    outer_spec = root.parent / "PROJECT_SPEC.md"
    if repo_spec.is_file() and outer_spec.is_file():
        outer_text = outer_spec.read_text(encoding="utf-8", errors="replace")
        rel = "../PROJECT_SPEC.md"
        if _DEPRECATION_MARKER in outer_text:
            findings.append(
                Finding(
                    "info",
                    "historical_copy",
                    rel,
                    0,
                    "根目录 PROJECT_SPEC 是历史副本（含弃用标记）；"
                    "当前真相是 docs/PROJECT_SPEC.md 与 docs/AFTER_M5_PLAN.md",
                )
            )
        else:
            findings.append(
                Finding(
                    "warning",
                    "historical_copy_missing_marker",
                    rel,
                    0,
                    "根目录 PROJECT_SPEC 缺少弃用标记，可能被误当当前规格",
                )
            )
    return findings


def _rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.name


def run_scan(root: Path) -> list[Finding]:
    return scan_code(root) + scan_docs(root)


def exit_code(findings: Sequence[Finding]) -> int:
    return 1 if any(f.severity == "error" for f in findings) else 0


def main(argv: Sequence[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(default_root), help="仓库根目录")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = parser.parse_args(argv)

    findings = run_scan(Path(args.root))
    code = exit_code(findings)
    if args.json:
        counts = {
            severity: sum(1 for f in findings if f.severity == severity)
            for severity in ("error", "warning", "info")
        }
        print(
            json.dumps(
                {
                    "findings": [f.to_dict() for f in findings],
                    "summary": {
                        "errors": counts["error"],
                        "warnings": counts["warning"],
                        "infos": counts["info"],
                        "files_scanned": len(_code_files(Path(args.root))),
                    },
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        for finding in findings:
            where = f"{finding.file}:{finding.line}" if finding.line else finding.file
            print(f"[{finding.severity.upper():7}] {finding.kind} {where}")
            print(f"          {finding.message}")
        print(
            f"ui_doc_drift_scan: {len(findings)} finding(s), "
            f"exit={code}（只有 error 级别的脆弱定位才非零）"
        )
    return code


if __name__ == "__main__":
    sys.exit(main())
