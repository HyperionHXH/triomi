import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from tools.ui_doc_drift_scan import (
    exit_code,
    main,
    run_scan,
    scan_line,
)


def kinds(findings):
    return {f[0] if isinstance(f, tuple) else f.kind for f in findings}


class ScanLineTest(unittest.TestCase):
    def test_fixed_index_in_nav_context_is_flagged(self) -> None:
        findings = scan_line("chips[2].click()  # 选择第二个来源")
        self.assertEqual(kinds(findings), {"fixed_index_nav"})

    def test_loop_variable_is_not_flagged(self) -> None:
        self.assertEqual(scan_line("for i in range(3): tap(chips[i])"), [])
        self.assertEqual(scan_line("for (final tab in tabs) print(tab);"), [])

    def test_first_element_index_is_allowed(self) -> None:
        self.assertEqual(scan_line("chips[0].click()"), [])

    def test_data_assertion_without_nav_context_is_not_flagged(self) -> None:
        # 解析层单测的数据列表断言不是 UI 导航。
        self.assertEqual(scan_line("expect(snapshot.items[1].title, '合集甲');"), [])

    def test_positional_label_is_flagged(self) -> None:
        findings = scan_line("box = d.find('第 2 个标签')")
        self.assertEqual(kinds(findings), {"positional_label"})
        self.assertEqual(kinds(scan_line("expect(find.text('第 3 项'), findsOneWidget)")), {"positional_label"})

    def test_semantic_label_is_not_flagged(self) -> None:
        self.assertEqual(scan_line("d.tap('本地夹具番剧源')"), [])

    def test_suppression_marker_honoured(self) -> None:
        self.assertEqual(scan_line("chips[2].click()  # drift-scan: allow"), [])


class RepositoryScanTest(unittest.TestCase):
    def _write(self, root: Path, rel: str, text: str) -> None:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_scan_reports_only_relative_paths_and_expected_kinds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "tools/device_step.py",
                "def open_player():\n    chips[1].click()\n",
            )
            self._write(
                root,
                "lib/features/player/player_page.dart",
                "// 纯 UI 代码，无固定索引\nfinal view = Text('ok');\n",
            )
            findings = run_scan(root)
            self.assertEqual(kinds(findings), {"fixed_index_nav"})
            self.assertEqual(findings[0].file, "tools/device_step.py")
            self.assertEqual(findings[0].line, 2)
            self.assertEqual(exit_code(findings), 1)

    def test_python_unit_tests_are_not_scanned(self) -> None:
        # tools/test_*.py 不是设备脚本：夹具字符串不应触发自举报。
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "tools/test_something.py",
                "SAMPLE = \"d.find('第 2 个标签')\"\n",
            )
            self.assertEqual(run_scan(root), [])

    def test_generated_dart_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "lib/core/db/app_database.g.dart",
                "final tabs = tabsView[2];\n",
            )
            self.assertEqual(run_scan(root), [])

    def test_stale_task_warning_without_exit_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/AFTER_M5_PLAN.md",
                "# 计划\n\n- [ ] **T1（M0）**：脚手架\n- [ ] D3 导出 UTF-8 TXT\n"
                "- [x] D8 追踪网络边界回归\n- [ ] D11 新任务不受旧编号误伤\n",
            )
            findings = run_scan(root)
            self.assertEqual(kinds(findings), {"stale_task"})
            self.assertEqual(exit_code(findings), 0, msg="警告不导致非零")
            messages = " ".join(f.message for f in findings)
            self.assertIn("T1", messages)
            self.assertIn("D3", messages)
            # D8 已完成（[x]）与 D11（新编号）都不能命中旧模式。
            self.assertNotIn("D8 追踪", messages)
            self.assertNotIn("D11", messages)

    def test_historical_doc_is_reported_as_info(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/NEXT_PLAN.md",
                "# 执行评估与下一步规划（历史记录）\n\n- [ ] T1 待办\n",
            )
            # NEXT_PLAN 不在当前文档清单里，不产生任何 finding。
            self.assertEqual(run_scan(root), [])
            self._write(
                root,
                "docs/AFTER_M5_PLAN.md",
                "# 计划（历史）\n\n> 本文件是历史记录\n\n- [ ] T1 待办\n",
            )
            findings = run_scan(root)
            self.assertEqual(kinds(findings), {"historical_doc"})
            self.assertEqual(findings[0].severity, "info")

    def test_two_project_specs_are_compared(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/PROJECT_SPEC.md", "# 规格\n")
            self._write(
                root.parent,
                "PROJECT_SPEC.md",
                "# 根目录副本\n\n> 状态提示：不作为当前执行状态；当前见 docs/\n",
            )
            findings = run_scan(root)
            self.assertEqual(kinds(findings), {"historical_copy"})
            self.assertEqual(findings[0].severity, "info")
            self.assertEqual(findings[0].file, "../PROJECT_SPEC.md")

    def test_outer_spec_without_deprecation_marker_warns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/PROJECT_SPEC.md", "# 规格\n")
            self._write(root.parent, "PROJECT_SPEC.md", "# 看起来像当前规格\n")
            findings = run_scan(root)
            self.assertEqual(
                kinds(findings),
                {"historical_copy_missing_marker"},
            )
            self.assertEqual(findings[0].severity, "warning")


class MainTest(unittest.TestCase):
    def test_json_output_and_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tools").mkdir()
            (root / "tools" / "script.py").write_text(
                "tabs[2].click()\n", encoding="utf-8"
            )
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(["--root", str(root), "--json"])
            self.assertEqual(code, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["summary"]["errors"], 1)
            self.assertEqual(payload["findings"][0]["kind"], "fixed_index_nav")
            self.assertNotIn(str(root), stdout.getvalue(), msg="JSON 不带绝对路径")

    def test_clean_repo_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "lib").mkdir()
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(["--root", str(root), "--json"])
            self.assertEqual(code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["findings"], [])


if __name__ == "__main__":
    unittest.main()
