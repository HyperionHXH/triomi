import tempfile
from pathlib import Path
import unittest

from package_windows import msi_version, package_windows


class WindowsPackageTests(unittest.TestCase):
    def test_build_number_participates_in_msi_upgrade_order(self):
        def fields(version, build):
            return tuple(map(int, msi_version(version, build).split('.')))
        self.assertLess(fields('0.1.0', 153), fields('0.1.0', 154))
        self.assertLess(fields('0.1.9', 65535), fields('0.2.0', 1))
        self.assertEqual(fields('255.255.0', 65535), (255, 255, 65535))

    def test_version_overflow_and_missing_build_are_rejected_not_wrapped(self):
        for version, build in [('0.1.0', 0), ('0.1.0', 65536), ('256.1.0', 1),
                               ('1.256.0', 1), ('1.0', 1), ('1.0.0-beta', 1)]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                msi_version(version, build)

    def test_missing_runtime_or_private_material_never_reaches_installer(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            bundle = root / 'bundle'
            bundle.mkdir()
            for private in [None, 'signing.properties', 'Signing.Properties', 'private.p12', 'debug.pdb']:
                if private:
                    (bundle / private).write_bytes(b'not publishable')
                with self.subTest(private=private), self.assertRaises(ValueError):
                    package_windows(bundle, root / 'output', '0.1.0', 153, 'must-not-run')
                if private:
                    (bundle / private).unlink()

    def test_output_inside_bundle_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = Path(root)
            with self.assertRaises(ValueError):
                package_windows(bundle, bundle / 'output', '0.1.0', 153, 'must-not-run')
            self.assertFalse((bundle / 'output').exists())


if __name__ == '__main__':
    unittest.main()
