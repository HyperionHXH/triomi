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
            findings, _ = run_scan(root)
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
            self.assertEqual(run_scan(root)[0], [])

    # -------------------------------------------------- D15 扫描范围语义

    def test_clean_checkout_ignores_retired_parent_scripts(self) -> None:
        # 默认只读仓库：仓库外留着的 _e2e_* / 历史 video 脚本不自动进扫描，
        # 也不产生任何 unreadable/missing 噪音。
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root = parent / "triomi"
            root.mkdir()
            self._write(parent, "_e2e_drive.py", "chips[1].click()\n")
            self._write(parent, "_video_check.py", "d.find('第 2 个标签')\n")
            self._write(root, "lib/app.dart", "void main() {}\n")
            findings, device_scanned = run_scan(root)
            self.assertEqual(findings, [])
            self.assertEqual(device_scanned, 0)

    def test_explicit_device_script_is_scanned_and_labelled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root = parent / "triomi"
            root.mkdir()
            self._write(
                parent,
                "_video_pixel_verify.py",
                "d.tap('第 2 个标签')\n",
            )
            findings, device_scanned = run_scan(
                root, [parent / "_video_pixel_verify.py"]
            )
            self.assertEqual(kinds(findings), {"positional_label"})
            self.assertEqual(findings[0].file, "../_video_pixel_verify.py")
            self.assertEqual(exit_code(findings), 1)
            self.assertEqual(device_scanned, 1)

    def test_missing_device_script_warns_instead_of_being_silent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            findings, device_scanned = run_scan(root, [root.parent / "_nope.py"])
            self.assertEqual(kinds(findings), {"device_script_missing"})
            self.assertEqual(findings[0].severity, "warning")
            self.assertEqual(exit_code(findings), 0)
            self.assertEqual(device_scanned, 0)

    def test_generated_dart_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "lib/core/db/app_database.g.dart",
                "final tabs = tabsView[2];\n",
            )
            self.assertEqual(run_scan(root)[0], [])

    # -------------------------------------------------- D15 编号语义区分

    def test_requirement_checklist_D_numbers_are_not_stale_tasks(self) -> None:
        # 规格 2.4 的「下载要求 D1–D5」是产品需求，不因编号与旧工作单相同
        # 被判为文档漂移；同一行在普通章节下仍要报警。
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/AFTER_M5_PLAN.md",
                "# 计划\n\n"
                "## 2.4 Mixn 功能全量清单（小说模块验收基准，逐项不可缺）\n\n"
                "- [ ] D1 整本或指定分卷下载\n"
                "- [ ] T3 阅读器\n\n"
                "## 交接任务清单\n\n"
                "- [ ] D3 导出 UTF-8 TXT\n",
            )
            findings, _ = run_scan(root)
            self.assertEqual(kinds(findings), {"stale_task"})
            self.assertEqual(len(findings), 1)
            self.assertIn("导出 UTF-8 TXT", findings[0].message)

    def test_stale_task_warning_without_exit_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/AFTER_M5_PLAN.md",
                "# 计划\n\n- [ ] **T1（M0）**：脚手架\n- [ ] D3 导出 UTF-8 TXT\n"
                "- [x] D8 追踪网络边界回归\n- [ ] D11 新任务不受旧编号误伤\n",
            )
            findings, _ = run_scan(root)
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
            self.assertEqual(run_scan(root)[0], [])
            self._write(
                root,
                "docs/AFTER_M5_PLAN.md",
                "# 计划（历史）\n\n> 本文件是历史记录\n\n- [ ] T1 待办\n",
            )
            findings, _ = run_scan(root)
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
            findings, _ = run_scan(root)
            self.assertEqual(kinds(findings), {"historical_copy"})
            self.assertEqual(findings[0].severity, "info")
            self.assertEqual(findings[0].file, "../PROJECT_SPEC.md")

    def test_outer_spec_without_deprecation_marker_warns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root, "docs/PROJECT_SPEC.md", "# 规格\n")
            self._write(root.parent, "PROJECT_SPEC.md", "# 看起来像当前规格\n")
            findings, _ = run_scan(root)
            self.assertEqual(
                kinds(findings),
                {"historical_copy_missing_marker"},
            )
            self.assertEqual(findings[0].severity, "warning")

    # -------------------------------------------------- D34 扫描范围扩展

    def test_new_batch_checkboxes_are_not_stale_tasks(self) -> None:
        # 第四轮及以后的工作单编号（D8+、D27-D38）不属于「旧待开发」模式；
        # 工作单里的未勾选状态是正常记录，不得误报成文档漂移。
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/GLM_BATCH_D27_D34.md",
                "# 批次\n\n| D27 | C2 发布管理页面 |\n\n"
                "- [ ] D35 备份数据库与设置导入的跨存储原子性\n"
                "- [ ] T9 假想任务\n",
            )
            self.assertEqual(run_scan(root)[0], [])

    def test_acceptance_matrix_is_in_scan_scope(self) -> None:
        # 验收矩阵进入当前真相清单：残留旧工作单待办仍要报 warning。
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/ACCEPTANCE_MATRIX.md",
                "# 验收矩阵\n\n- [ ] T3 阅读器待办不应出现\n",
            )
            findings, _ = run_scan(root)
            self.assertEqual(kinds(findings), {"stale_task"})
            self.assertEqual(findings[0].file, "docs/ACCEPTANCE_MATRIX.md")

    def test_platform_audit_doc_without_stale_items_is_clean(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(
                root,
                "docs/PLATFORM_DEPENDENCY_AUDIT.md",
                "# 盘点\n\n- [x] D28 Windows 播放依赖已锁定\n",
            )
            self.assertEqual(run_scan(root)[0], [])


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
            self.assertEqual(payload["summary"]["files_scanned"], 1)
            self.assertEqual(payload["summary"]["device_scripts_scanned"], 0)
            self.assertEqual(payload["findings"][0]["kind"], "fixed_index_nav")
            self.assertNotIn(str(root), stdout.getvalue(), msg="JSON 不带绝对路径")

    def test_explicit_device_script_in_json_counts_and_no_absolute_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root = parent / "triomi"
            (root / "lib").mkdir(parents=True)
            script = parent / "_video_pixel_verify.py"
            script.write_text("chips[1].click()\n", encoding="utf-8")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(
                    [
                        "--root",
                        str(root),
                        "--device-script",
                        str(script),
                        "--json",
                    ]
                )
            self.assertEqual(code, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["summary"]["device_scripts_scanned"], 1)
            self.assertEqual(payload["findings"][0]["file"], "../_video_pixel_verify.py")
            self.assertNotIn(str(parent), stdout.getvalue(), msg="JSON 不带绝对路径")

    def test_missing_device_script_is_a_json_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "lib").mkdir()
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(
                    [
                        "--root",
                        str(root),
                        "--device-script",
                        str(root.parent / "_gone.py"),
                        "--json",
                    ]
                )
            self.assertEqual(code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["summary"]["warnings"], 1)
            self.assertEqual(payload["findings"][0]["kind"], "device_script_missing")
            self.assertEqual(payload["summary"]["device_scripts_scanned"], 0)

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
