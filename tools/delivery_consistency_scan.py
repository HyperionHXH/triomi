"""Repo consistency scan for delivery documents (D44).

Scans ``docs/delivery/`` and the batch work orders for three failure modes
that previously let documentation drift silently:

- ``missing_delivery`` (error): a task listed in a ``GLM_BATCH_*.md`` work
  order has no ``docs/delivery/Dxx.md``.
- ``broken_reference`` (error): a delivery doc references a repo file
  (``test/…``、``lib/…``、``tools/…``、``docs/…``、``.github/…``) that does
  not exist — the doc's evidence points at nothing.
- ``missing_section`` (warning): a delivery doc lacks one of the template
  sections (任务 / 完成范围 / 验证) — evidence exists but is unstructured.
- ``missing_summary`` (error): a batch work order lacks its
  ``docs/delivery/BATCH_*_SUMMARY.md``.

Only repository files are read; findings carry repo-relative posix paths.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
import argparse
import json
from pathlib import Path
import re
import sys
from typing import Sequence

_TASK_ROW_RE = re.compile(r"^\|\s*(D\d+)\s*\|", re.MULTILINE)
_DELIVERY_DIR = "docs/delivery"
_SECTION_MARKERS = ("任务", "完成范围", "验证")
_REFERENCE_RE = re.compile(
    r"`((?:test|lib|tools|docs|assets|android|windows)/[A-Za-z0-9_\-./]+"
    r"|\.github/workflows/[A-Za-z0-9_.\-]+)`"
)


@dataclass(frozen=True)
class Finding:
    severity: str  # error | warning
    kind: str
    file: str
    message: str

    def to_dict(self) -> dict[str, str]:
        return asdict(self)


def _repo_files(root: Path) -> set[str]:
    files: set[str] = set()
    for base in ("test", "lib", "tools", "docs", "assets", "android", "windows", ".github"):
        directory = root / base
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts:
                try:
                    files.add(path.relative_to(root).as_posix())
                except ValueError:
                    continue
    return files


def _delivery_doc_path(task: str) -> str:
    return f"{_DELIVERY_DIR}/{task}.md"


def _mentions_task(content: str, task: str) -> bool:
    """D55：任务标识必须独立成词——`D10` 不能当作对 `D1` 的提及
    （朴素子串匹配会把 D1/D10、D2/D20 混为一谈）。"""
    return (
        re.search(rf"(?<![A-Za-z0-9]){re.escape(task)}(?![0-9])", content)
        is not None
    )


def _has_covering_summary(
    root: Path, tasks: Sequence[str], files: set[str]
) -> bool:
    """A batch is summarised when some BATCH_*_SUMMARY.md names a matching
    range or its content mentions every task of the batch — 合并汇总
    （如 D15–D26 一份）也算覆盖。"""

    for rel in sorted(files):
        name = Path(rel).name
        if not (rel.startswith(f"{_DELIVERY_DIR}/BATCH_") and name.endswith("_SUMMARY.md")):
            continue
        stem = name[len("BATCH_"):-len("_SUMMARY.md")]
        match = re.search(r"D(\d+)_D(\d+)", stem)
        if match:
            lo, hi = int(match.group(1)), int(match.group(2))
            numbers = [int(task[1:]) for task in tasks]
            if numbers and lo <= min(numbers) and max(numbers) <= hi:
                return True
        content = (root / rel).read_text(encoding="utf-8", errors="replace")
        if all(_mentions_task(content, task) for task in tasks):
            return True
    return False


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    files = _repo_files(root)

    # 1. 工作单任务表 → 交付文档存在性 + 批次汇总。
    for work_order in sorted((root / "docs").glob("GLM_BATCH_*.md")):
        text = work_order.read_text(encoding="utf-8", errors="replace")
        rel_order = work_order.relative_to(root).as_posix()
        tasks = _TASK_ROW_RE.findall(text)
        planned = re.search(r"^状态：待执行\s*$", text, re.MULTILINE) is not None
        for task in tasks:
            delivery = _delivery_doc_path(task)
            if delivery not in files and not planned:
                findings.append(
                    Finding(
                        "error",
                        "missing_delivery",
                        rel_order,
                        f"工作单任务 {task} 缺少交付文档 {delivery}",
                    )
                )
        if tasks and not planned and not _has_covering_summary(root, tasks, files):
            findings.append(
                Finding(
                    "error",
                    "missing_summary",
                    rel_order,
                    "批次缺少覆盖全部任务的 BATCH_*_SUMMARY.md 汇总文档",
                )
            )

    # 2. 交付文档结构 + 引用完整性。
    delivery_dir = root / _DELIVERY_DIR
    if delivery_dir.is_dir():
        for doc in sorted(delivery_dir.glob("*.md")):
            if doc.name.startswith("BATCH_"):
                continue  # 汇总不套单任务模板
            rel = doc.relative_to(root).as_posix()
            text = doc.read_text(encoding="utf-8", errors="replace")
            for marker in _SECTION_MARKERS:
                if marker not in text:
                    findings.append(
                        Finding(
                            "warning",
                            "missing_section",
                            rel,
                            f"交付文档缺少「{marker}」段（模板不完整）",
                        )
                    )
            for match in _REFERENCE_RE.finditer(text):
                ref = match.group(1)
                if "*" in ref or ref.endswith("/"):
                    continue  # 通配与目录引用不校验
                if ref not in files:
                    findings.append(
                        Finding(
                            "error",
                            "broken_reference",
                            rel,
                            f"交付文档引用的文件不存在：{ref}",
                        )
                    )
    return findings


def main(argv: Sequence[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(default_root), help="仓库根目录")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = parser.parse_args(argv)

    findings = scan(Path(args.root))
    code = 1 if any(f.severity == "error" for f in findings) else 0
    if args.json:
        print(
            json.dumps(
                {
                    "findings": [f.to_dict() for f in findings],
                    "summary": {
                        "errors": sum(
                            1 for f in findings if f.severity == "error"
                        ),
                        "warnings": sum(
                            1 for f in findings if f.severity == "warning"
                        ),
                    },
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        for finding in findings:
            print(f"[{finding.severity.upper():7}] {finding.kind} {finding.file}")
            print(f"          {finding.message}")
        print(
            f"delivery_consistency_scan: {len(findings)} finding(s), exit={code}"
            "（只有 error 级别才非零）"
        )
    return code


if __name__ == "__main__":
    sys.exit(main())
