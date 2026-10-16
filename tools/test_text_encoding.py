"""D83：仓库文本编码回归（UTF-8 / 无替换字符）纳入 unittest 发现。"""

import unittest
from pathlib import Path

from tools.check_text_encoding import find_encoding_errors, tracked_paths


class TextEncodingTest(unittest.TestCase):
    def test_tracked_text_files_are_utf8_without_replacement_chars(self) -> None:
        root = Path(__file__).resolve().parent.parent
        errors = find_encoding_errors(root, tracked_paths(root))
        self.assertEqual(
            errors,
            [],
            msg=f"仓库存在非 UTF-8 或含替换字符的文本文件：{errors}",
        )

    def test_synthetic_bad_bytes_are_reported(self) -> None:
        # 用合成文件证明扫描器真的能抓到非 UTF-8 字节（守卫不空转）。
        import tempfile

        from tools.check_text_encoding import find_encoding_errors as scan

        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.md"
            bad.write_bytes("中文".encode("gbk"))
            errors = scan(Path(tmp), ["bad.md"])
        self.assertEqual(len(errors), 1)
        self.assertIn("invalid UTF-8", errors[0])


if __name__ == "__main__":
    unittest.main()
