"""Platform-independent contract tests for iOS SDK selection and IPA validation."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import package_ios
import resolve_ios_toolchain


class IosToolchainTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        workflows = self.root / '.github' / 'workflows'
        workflows.mkdir(parents=True)
        for name in ('build.yml', 'release.yml'):
            (workflows / name).write_text("name: build\nenv:\n  FLUTTER_VERSION: '3.47.5'\njobs:\n", encoding='utf-8')
        (self.root / 'pubspec.yaml').write_text('environment:\n  sdk: ^3.13.4\n', encoding='utf-8')
        root = patch.object(resolve_ios_toolchain, 'ROOT', self.root)
        root.start()
        self.addCleanup(root.stop)

    def test_reuses_exact_existing_pins(self):
        self.assertEqual(resolve_ios_toolchain.repository_toolchain(), ('3.47.5', (3, 13, 4)))

    def test_disagreement_fails_without_fallback(self):
        (self.root / '.github/workflows/release.yml').write_text("env:\n  FLUTTER_VERSION: '3.47.4'\n", encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'disagree'):
            resolve_ios_toolchain.repository_toolchain()

    def test_installed_sdk_must_satisfy_dart_minimum(self):
        machine = '{"frameworkVersion":"3.47.5","channel":"stable","dartSdkVersion":"3.13.3"}'
        with patch.object(resolve_ios_toolchain.subprocess, 'check_output', return_value=machine):
            with self.assertRaisesRegex(ValueError, 'does not satisfy'):
                resolve_ios_toolchain.verify_installed('3.47.5', (3, 13, 4))

    def test_installed_sdk_cannot_switch_to_a_different_flutter(self):
        machine = '{"frameworkVersion":"3.47.6","channel":"stable","dartSdkVersion":"3.13.4"}'
        with patch.object(resolve_ios_toolchain.subprocess, 'check_output', return_value=machine):
            with self.assertRaisesRegex(ValueError, 'exact stable SDK pin'):
                resolve_ios_toolchain.verify_installed('3.47.5', (3, 13, 4))


class IosPayloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.app = root / 'Runner.app'
        self.app.mkdir()
        (root / 'pubspec.yaml').write_text('version: 1.2.3+45\n', encoding='utf-8')
        self.info = {
            'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'Runner',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'DTPlatformName': 'iphoneos',
            'LSRequiresIPhoneOS': True, 'CFBundleIdentifier': 'com.example.triomi',
            'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '45',
            'MinimumOSVersion': '14.0',
        }
        self.write_plist(self.app / 'Info.plist', self.info)
        (self.app / 'Runner').write_bytes(b'\xcf\xfa\xed\xfe' + b'unit-test-binary')
        for name in ('App', 'Flutter'):
            framework = self.app / 'Frameworks' / f'{name}.framework'
            framework.mkdir(parents=True)
            self.write_plist(framework / 'Info.plist', {
                'CFBundlePackageType': 'FMWK', 'CFBundleExecutable': name,
            })
            (framework / name).write_bytes(b'\xcf\xfa\xed\xfe' + b'unit-test-binary')
        (self.app / 'Frameworks/App.framework/flutter_assets').mkdir()
        root_patch = patch.object(package_ios, 'ROOT', root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    @staticmethod
    def write_plist(path, values):
        path.write_bytes(plistlib.dumps(values))

    def test_wrong_build_number_fails_before_packaging(self):
        self.info['CFBundleVersion'] = '44'
        self.write_plist(self.app / 'Info.plist', self.info)
        with self.assertRaisesRegex(ValueError, 'does not match'):
            package_ios.validate_application(self.app)

    def test_missing_nested_framework_binary_is_rejected(self):
        (self.app / 'Frameworks/Flutter.framework/Flutter').unlink()
        with patch.object(package_ios, 'check_macho'):
            with self.assertRaisesRegex(ValueError, 'Missing bundle executable'):
                package_ios.validate_application(self.app)

    def test_provisioning_and_private_keys_are_rejected(self):
        for name, content in (
            ('embedded.mobileprovision', b'profile'),
            ('config.txt', b'-----BEGIN PRIVATE KEY-----\nsecret'),
        ):
            with self.subTest(name=name):
                artifact = self.app / name
                artifact.write_bytes(content)
                with patch.object(package_ios, 'check_macho'):
                    with self.assertRaisesRegex(ValueError, 'Credentials|Private key'):
                        package_ios.validate_application(self.app)
                artifact.unlink()

    def test_arm64_simulator_is_not_a_device_binary(self):
        with patch.object(package_ios, 'command', side_effect=['arm64', 'cmd LC_BUILD_VERSION\n platform 7\n']):
            with self.assertRaisesRegex(ValueError, 'Not an iPhoneOS binary'):
                package_ios.check_macho(self.app / 'Runner')

    def test_intel_framework_is_rejected(self):
        with patch.object(package_ios, 'command', return_value='x86_64'):
            with self.assertRaisesRegex(ValueError, 'arm64-only'):
                package_ios.check_macho(self.app / 'Runner')

    def test_development_identity_is_rejected(self):
        signature = subprocess.CompletedProcess([], 0, '', 'Authority=Apple Development: Test\n')
        with patch.object(package_ios.subprocess, 'run', return_value=signature):
            with self.assertRaisesRegex(ValueError, 'Development signature'):
                package_ios.check_signature(self.app / 'Runner', application=True)

    def test_development_entitlement_is_rejected(self):
        signature = subprocess.CompletedProcess([], 0, '', 'Signature=adhoc\n')
        entitlements = subprocess.CompletedProcess([], 0, plistlib.dumps({'get-task-allow': True}).decode(), '')
        with patch.object(package_ios.subprocess, 'run', side_effect=[signature, entitlements]):
            with self.assertRaisesRegex(ValueError, 'Development/JIT entitlements'):
                package_ios.check_signature(self.app / 'Runner', application=True)


if __name__ == '__main__':
    unittest.main()
