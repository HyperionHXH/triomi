import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from build_update_manifest import build_manifest


class UpdateManifestTests(unittest.TestCase):
    def test_streamed_members_have_exact_hashes_and_bundle_identity(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = Path(root) / 'triomi.zip'
            members = {'triomi.exe': b'PE fixture', 'flutter_windows.dll': b'engine', 'data/a.txt': b'content'}
            with zipfile.ZipFile(bundle, 'w') as archive:
                for name, content in members.items():
                    archive.writestr(name, content)
            result = build_manifest(bundle, '0.1.0', 148)
            self.assertEqual(result['sha256'], hashlib.sha256(bundle.read_bytes()).hexdigest())
            self.assertEqual(result['files'], {name: {'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
                                               for name, content in members.items()})

    def test_unsafe_duplicate_and_missing_runtime_bundles_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            for entries in [
                    ['triomi.exe', 'flutter_windows.dll', '../outside'],
                    ['triomi.exe', 'flutter_windows.dll', 'TRIOMI.EXE'],
                    ['triomi.exe', 'flutter_windows.dll', 'data//bad'],
                    ['triomi.exe']]:
                bundle = Path(root) / 'triomi.zip'
                with zipfile.ZipFile(bundle, 'w') as archive:
                    for name in entries:
                        archive.writestr(name, b'x')
                with self.assertRaises(ValueError):
                    build_manifest(bundle, '0.1.0', 148)


if __name__ == '__main__':
    unittest.main()
