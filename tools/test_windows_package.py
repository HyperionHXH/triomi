import tempfile
from pathlib import Path
import uuid
import unittest

from package_windows import IDENTITY, UPGRADE_CODE, WIX_NS, installer_source, msi_version, package_windows


class WindowsPackageTests(unittest.TestCase):
    def installer(self, revision, version='0.15.3', build=188):
        tree = installer_source(Path('bundle'), ['triomi.exe'], version, build,
                                Path('app.ico'), Path('license.rtf'), windows_revision=revision)
        return tree.getroot().find(f'{{{WIX_NS}}}Package')


    def test_revision_component_is_shared_but_scoped_to_version_and_build(self):
        ns = {'w': WIX_NS}
        def marker(package):
            return next(component for component in package.findall('.//w:Component', ns)
                        if any(value.get('Name') == 'InstalledWindowsRevision'
                               for value in component.findall('w:RegistryValue', ns)))
        packages = [self.installer(revision) for revision in (0, 1, 2)]
        markers = [marker(package) for package in packages]
        self.assertEqual(len({component.get('Id') for component in markers}), 1)
        self.assertEqual(len({component.get('Guid') for component in markers}), 1)
        self.assertEqual(len({package.get('ProductCode') for package in packages}), 3)
        self.assertEqual(packages[0].get('ProductCode'),
                         str(uuid.uuid5(IDENTITY, 'product:0.15.3+188')))
        for package, component in zip(packages, markers):
            self.assertEqual(package.get('UpgradeCode'), UPGRADE_CODE)
            self.assertEqual(package.get('Version'), '0.15.188')
            self.assertEqual(component.find('w:RegistryValue', ns).get('KeyPath'), 'yes')
            refs = {ref.get('Id') for ref in package.findall('w:Feature/w:ComponentRef', ns)}
            self.assertIn(component.get('Id'), refs)
        original = markers[0].find('w:RegistryValue', ns).get('Key')
        for version, build in [('0.15.4', 188), ('0.15.3', 189)]:
            other = marker(self.installer(1, version, build))
            self.assertNotEqual(other.get('Guid'), markers[0].get('Guid'))
            self.assertNotEqual(other.find('w:RegistryValue', ns).get('Key'), original)

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
