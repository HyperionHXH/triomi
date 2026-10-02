import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from tools.delivery_consistency_scan import main, scan


def kinds(findings):
    return {f.kind for f in findings}


class DeliveryConsistencyScanTest(unittest.TestCase):
    def test_explicit_planned_batch_does_not_require_completed_deliveries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/GLM_BATCH_D47_D58.md",
                        "# 批次\n状态：待执行\n| D47 | 测试 |\n")
            self.assertEqual(scan(root), [])

    def _write(self, root: Path, rel: str, text: str) -> None:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def _minimal_delivery(self, references: str = "") -> str:
        return (
            "# D27 交付：示例\n\n任务：D27\n\n## 完成范围\n\n| 文件 |\n"
            f"|---|\n| {references} |\n\n## 验证\n\n全部通过。\n"
        )

    def test_missing_delivery_doc_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/WORK.md", "# 批次\n\n| 任务 | 工作 |\n|---|---|\n")
            self._write(
                root,
                "docs/GLM_BATCH_D50_D51.md",
                "# 批次\n\n| 任务 | 工作 |\n|---|---|\n"
                "| D50 | 甲 |\n| D51 | 乙 |\n",
            )
            self._write(root, "docs/delivery/D50.md", self._minimal_delivery())

            findings = scan(root)
            self.assertEqual(
                kinds(findings),
                {"missing_delivery", "missing_summary"},
                msg="工作单既缺 D51 交付文档也缺批次汇总",
            )
            missing = [f for f in findings if f.kind == "missing_delivery"]
            self.assertEqual(len(missing), 1)
            self.assertIn("D51", missing[0].message)
            self.assertEqual(exit_code_of(findings), 1)

    def test_missing_batch_summary_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/GLM_BATCH_D60_D60.md",
                "# 批次\n\n| 任务 | 工作 |\n|---|---|\n| D60 | 甲 |\n",
            )
            self._write(root, "docs/delivery/D60.md", self._minimal_delivery())
            findings = scan(root)
            self.assertEqual(kinds(findings), {"missing_summary"})

    def test_broken_reference_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root, "docs/delivery/D61.md", self._minimal_delivery(
                    references="`test/does_not_exist_test.dart`",
                )
            )
            findings = scan(root)
            self.assertEqual(kinds(findings), {"broken_reference"})
            self.assertIn("does_not_exist", findings[0].message)

    def test_existing_reference_passes_and_skips_globs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "test/real_test.dart", "void main() {}")
            self._write(
                root,
                "docs/delivery/D62.md",
                self._minimal_delivery(
                    references="`test/real_test.dart` 与 `test/fixtures/**`"
                ),
            )
            self.assertEqual(scan(root), [])

    def test_missing_template_section_is_a_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/delivery/D63.md", "# 只有标题\n")
            findings = scan(root)
            self.assertEqual(kinds(findings), {"missing_section"})
            self.assertTrue(
                all(f.severity == "warning" for f in findings),
                msg="模板不完整是警告不是错误",
            )

    # -------------------------------------------------- D55 摘要标识边界

    def test_summary_range_stem_covers_whole_range(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows = "\n".join(f"| D{n} | 任务 |" for n in range(1, 11))
            self._write(
                root,
                "docs/GLM_BATCH_D1_D10.md",
                f"# 批次\n\n| 任务 | 工作 |\n|---|---|\n{rows}\n",
            )
            for n in range(1, 11):
                self._write(root, f"docs/delivery/D{n}.md", self._minimal_delivery())
            self._write(
                root,
                "docs/delivery/BATCH_D1_D10_SUMMARY.md",
                "# 汇总\n\nD1-D10 全部交付。\n",
            )
            self.assertEqual(scan(root), [])

    def test_summary_id_boundary_d1_is_not_d10(self) -> None:
        # 汇总内容只提到 D10（如「延续 D10 的结论」），不得当作对 D1 的覆盖；
        # 范围 1-2 的汇总也覆盖不到 D10。两处都必须报 missing_summary。
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/GLM_BATCH_D1_D2_D10.md",
                "# 批次\n\n| 任务 | 工作 |\n|---|---|\n"
                "| D1 | 甲 |\n| D2 | 乙 |\n| D10 | 丙 |\n",
            )
            for n in (1, 2, 10):
                self._write(root, f"docs/delivery/D{n}.md", self._minimal_delivery())
            self._write(
                root,
                "docs/delivery/BATCH_OLDER_SUMMARY.md",
                "# 汇总\n\n延续 D10 之前批次的结论。\n",
            )
            findings = scan(root)
            self.assertEqual(
                kinds(findings), {"missing_summary"},
                msg="子串误匹配修复后，仅提到 D10 的汇总覆盖不了 D1/D2/D10 整批",
            )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/GLM_BATCH_D1_D2_D10.md",
                "# 批次\n\n| 任务 | 工作 |\n|---|---|\n"
                "| D1 | 甲 |\n| D2 | 乙 |\n| D10 | 丙 |\n",
            )
            for n in (1, 2, 10):
                self._write(root, f"docs/delivery/D{n}.md", self._minimal_delivery())
            self._write(
                root,
                "docs/delivery/BATCH_OLDER_SUMMARY.md",
                "# 汇总\n\nD1、D2、D10 各自独立交付完成。\n",
            )
            self.assertEqual(
                scan(root), [],
                msg="三个标识都独立出现时内容提及路径应当生效",
            )

    def test_batch_summary_docs_skip_template_check(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/delivery/BATCH_D70_D70_SUMMARY.md", "# 汇总\n")
            self._write(
                root,
                "docs/GLM_BATCH_D70_D70.md",
                "# 批次\n\n| 任务 | 工作 |\n|---|---|\n| D70 | 甲 |\n",
            )
            self._write(root, "docs/delivery/D70.md", self._minimal_delivery())
            self.assertEqual(scan(root), [])


def contains_message(fragment: str):
    class _Contains:
        def __eq__(self, other):
            return fragment in other

        def __repr__(self):
            return f"contains({fragment!r})"

    return _Contains()


def exit_code_of(findings) -> int:
    return 1 if any(f.severity == "error" for f in findings) else 0


class MainTest(unittest.TestCase):
    def test_json_output_and_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "docs" / "delivery").mkdir(parents=True)
            (root / "docs" / "GLM_BATCH_D80_D80.md").write_text(
                "# 批次\n\n| 任务 | 工作 |\n|---|---|\n| D80 | 甲 |\n",
                encoding="utf-8",
            )
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(["--root", str(root), "--json"])
            self.assertEqual(code, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["summary"]["errors"], 2)
            kinds_found = {f["kind"] for f in payload["findings"]}
            self.assertEqual(kinds_found, {"missing_delivery", "missing_summary"})
            self.assertNotIn(str(root), stdout.getvalue(), msg="JSON 不带绝对路径")

    def test_real_repo_references_are_intact(self) -> None:
        # 真实仓库的自检只断言「引用完整性」（最容易漂移的部分）；
        # missing_delivery/missing_summary 依赖批次进行时状态，由临时目录
        # 单测覆盖结构规则。
        repo_root = Path(__file__).resolve().parent.parent
        findings = scan(repo_root)
        broken = [f for f in findings if f.kind == "broken_reference"]
        self.assertEqual(
            broken,
            [],
            msg=f"真实仓库存在失效引用：{[f.message for f in broken]}",
        )


if __name__ == "__main__":
    unittest.main()
