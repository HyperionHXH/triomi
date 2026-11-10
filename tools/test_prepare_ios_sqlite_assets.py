import hashlib
from pathlib import Path
import tempfile
import unittest

from prepare_ios_sqlite_assets import fetch, publish


class PinnedSqliteTests(unittest.TestCase):
    def test_http_error_body_cannot_replace_verified_binary(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'libsqlite3.dylib'
            original = b'original pinned binary'
            target.write_bytes(original)
            with self.assertRaises(ValueError):
                publish(b'<html>504 Gateway Time-out</html>', hashlib.sha256(original).hexdigest(), target)
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(list(Path(root).iterdir()), [target])

    def test_exact_hash_publishes_complete_binary_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'download-pin/libsqlite3.dylib'
            payload = bytes(range(256)) * 100
            publish(payload, hashlib.sha256(payload).hexdigest(), target)
            self.assertEqual(target.read_bytes(), payload)
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_nonofficial_asset_origin_rejected_before_network(self):
        with self.assertRaises(ValueError):
            fetch('https://api.github.com.evil.invalid/sqlite.dylib', binary=True)
        with self.assertRaises(ValueError):
            fetch('http://api.github.com/sqlite.dylib', binary=True)


if __name__ == '__main__':
    unittest.main()
