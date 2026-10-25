"""Validate an unsigned device release and zip its standard Payload into an IPA.

Requires macOS/Xcode tools. This does not sign, provision, install, or make an IPA
App-Store-ready. Ad-hoc signatures on embedded vendor binaries are permitted;
development identities, development entitlements and private keys are not.
"""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MACHO_MAGICS = {
    b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
}
PRIVATE_KEY_MARKERS = (
    b'-----BEGIN PRIVATE KEY-----', b'-----BEGIN ENCRYPTED PRIVATE KEY-----',
    b'-----BEGIN RSA PRIVATE KEY-----', b'-----BEGIN EC PRIVATE KEY-----',
    b'-----BEGIN OPENSSH PRIVATE KEY-----',
)
FORBIDDEN_ENTITLEMENTS = (
    'get-task-allow', 'com.apple.security.get-task-allow',
    'com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory',
    'com.apple.security.cs.disable-library-validation',
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def check_signature(binary: Path, *, application: bool) -> None:
    signature = subprocess.run(
        ['codesign', '-dvv', str(binary)], text=True, capture_output=True,
    )
    description = signature.stdout + signature.stderr
    if signature.returncode:
        require('not signed at all' in description, f'Cannot inspect signature: {binary}\n{description}')
        return
    require(not re.search(r'Authority=.*(?:Apple Development|iPhone Developer|Mac Developer)', description),
            f'Development signature found: {binary}')
    if application:
        require('Authority=' not in description, f'Runner must not carry a signing identity: {binary}')
    entitlements = subprocess.run(
        ['codesign', '-d', '--entitlements', ':-', str(binary)], text=True, capture_output=True,
    )
    require(entitlements.returncode == 0, f'Cannot inspect entitlements: {binary}')
    xml = entitlements.stdout
    if '<?xml' not in xml:
        return  # Unsigned/ad-hoc binaries commonly have no entitlement blob.
    values = plistlib.loads(xml[xml.index('<?xml'):].encode('utf-8'))
    require(not any(values.get(key) for key in FORBIDDEN_ENTITLEMENTS),
            f'Development/JIT entitlements found: {binary}')


def check_macho(binary: Path, *, application: bool = False) -> None:
    architectures = command('xcrun', 'lipo', '-archs', str(binary)).split()
    require('arm64' in architectures and set(architectures) <= {'arm64', 'arm64e'},
            f'Not an arm64-only iOS device binary: {binary}: {architectures}')
    load_commands = command('xcrun', 'otool', '-l', str(binary))
    platforms = re.findall(r'^\s*platform\s+(\S+)', load_commands, re.MULTILINE)
    require((platforms and all(p in ('2', 'IOS') for p in platforms)) or
            (not platforms and 'LC_VERSION_MIN_IPHONEOS' in load_commands),
            f'Not an iPhoneOS binary (simulator/macOS payload is invalid): {binary}')
    check_signature(binary, application=application)


def bundle_info(bundle: Path, package_type: str) -> tuple[dict, Path]:
    plist = bundle / 'Info.plist'
    require(plist.is_file(), f'Missing bundle metadata: {plist}')
    with plist.open('rb') as stream:
        info = plistlib.load(stream)
    require(info.get('CFBundlePackageType') == package_type, f'Wrong bundle type: {bundle}')
    executable = info.get('CFBundleExecutable', '')
    require(isinstance(executable, str) and bool(executable) and Path(executable).name == executable,
            f'Invalid bundle executable metadata: {bundle}')
    binary = bundle / executable
    require(binary.is_file(), f'Missing bundle executable: {binary}')
    with binary.open('rb') as stream:
        require(stream.read(4) in MACHO_MAGICS, f'Bundle executable is not Mach-O: {binary}')
    return info, binary


def validate_application(app: Path) -> dict:
    require(app.is_dir() and app.name == 'Runner.app', f'Expected built Runner.app: {app}')
    info, executable = bundle_info(app, 'APPL')
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Runner is not an iPhoneOS application')
    require(info.get('DTPlatformName') == 'iphoneos', 'Runner was not built with the device SDK')
    require(info.get('LSRequiresIPhoneOS') is True, 'Runner must require iOS')
    require(bool(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', info.get('CFBundleIdentifier', ''))),
            'Missing/invalid application bundle identifier')
    pubspec = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', pubspec, re.MULTILINE)
    require(version is not None, 'Expected pubspec version major.minor.patch+build')
    require(info.get('CFBundleShortVersionString') == version.group(1) and
            info.get('CFBundleVersion') == version.group(2), 'IPA version does not match pubspec.yaml')
    require(bool(re.fullmatch(r'\d+(?:\.\d+){0,2}', info.get('MinimumOSVersion', ''))),
            'Missing/invalid minimum iOS version')
    root = app.resolve()
    binaries = 0
    frameworks = 0
    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app)
        require(path.resolve().is_relative_to(root), f'Bundle symlink escapes the application: {relative}')
        name = path.name.lower()
        require(name != 'embedded.mobileprovision' and
                path.suffix.lower() not in ('.p12', '.pfx', '.key', '.jks', '.keystore', '.mobileprovision', '.xctest', '.dsym'),
                f'Credentials, provisioning or test/debug bundle in payload: {relative}')
        if path.is_dir() and path.suffix == '.framework':
            bundle_info(path, 'FMWK')
            frameworks += 1
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
            stream.seek(0)
            overlap = b''
            while chunk := stream.read(1024 * 1024):
                block = overlap + chunk
                require(not any(marker in block for marker in PRIVATE_KEY_MARKERS),
                        f'Private key found in payload: {relative}')
                overlap = block[-80:]
        if magic in MACHO_MAGICS:
            check_macho(path, application=path == executable)
            binaries += 1
    require((app / 'Frameworks' / 'Flutter.framework').is_dir(), 'Missing embedded Flutter engine')
    require((app / 'Frameworks' / 'App.framework').is_dir(), 'Missing compiled Flutter application')
    require((app / 'Frameworks' / 'App.framework' / 'flutter_assets').is_dir(), 'Missing Flutter assets')
    ech_framework = app / 'Frameworks' / 'ech_http.framework'
    ech_info, ech_binary = bundle_info(ech_framework, 'FMWK')
    minimum = tuple((list(map(int, info['MinimumOSVersion'].split('.'))) + [0, 0])[:3])
    ech_minimum = str(ech_info.get('MinimumOSVersion', '')).split('.')
    require(all(part.isdigit() for part in ech_minimum) and
            tuple((list(map(int, ech_minimum)) + [0, 0])[:3]) <= minimum,
            'ECH framework requires a newer iOS version than Runner')
    ech_commands = command('xcrun', 'otool', '-l', str(ech_binary))
    native_minimums = re.findall(r'^\s*minos\s+(\d+(?:\.\d+)*)', ech_commands, re.MULTILINE)
    require(bool(native_minimums) and
            all(tuple((list(map(int, value.split('.'))) + [0, 0])[:3]) <= minimum
                for value in native_minimums),
            'ECH native library is missing a compatible iOS deployment target')
    install_names = command('xcrun', 'otool', '-D', str(ech_binary)).splitlines()[1:]
    require([name.strip() for name in install_names if name.strip()] ==
            ['@rpath/ech_http.framework/ech_http'],
            'ECH native asset has an invalid framework install name')
    runner_commands = command('xcrun', 'otool', '-l', str(executable))
    require(bool(re.search(r'^\s*path\s+@executable_path/Frameworks\s+\(offset',
                           runner_commands, re.MULTILINE)),
            'Runner cannot resolve embedded native assets via its Frameworks rpath')
    require(binaries > 0 and frameworks >= 2, 'Missing native release binaries/frameworks')
    return {
        'bundleIdentifier': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'minimumOSVersion': info['MinimumOSVersion'], 'nativeBinaries': binaries,
        'frameworks': frameworks,
    }


def package_ios(app: Path, output: Path) -> None:
    require(sys.platform == 'darwin', 'iOS packaging validation requires macOS and Xcode')
    app = app.resolve()
    output = output.resolve()
    require(output.name == 'Triomi-iOS-Unsigned.ipa', 'Use the canonical Triomi-iOS-Unsigned.ipa asset name')
    require(not output.is_relative_to(app), 'IPA output must be outside Runner.app')
    metadata = validate_application(app)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='triomi-ios-', dir=output.parent) as temporary:
        stage = Path(temporary)
        payload = stage / 'Payload'
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        archive = stage / output.name
        # Preserve framework symlinks and executable modes; do not re-sign or strip.
        subprocess.run(['zip', '-r', '-y', str(archive), 'Payload'], cwd=stage, check=True)
        with zipfile.ZipFile(archive) as zipped:
            require(zipped.testzip() is None, 'IPA zip integrity check failed')
            require('Payload/Runner.app/Info.plist' in zipped.namelist(), 'Missing standard IPA payload')
            for name in zipped.namelist():
                member = PurePosixPath(name)
                require(not member.is_absolute() and '..' not in member.parts and
                        (name == 'Payload/' or name.startswith('Payload/Runner.app/')),
                        f'Unexpected IPA archive entry: {name}')
            require(plistlib.loads(zipped.read('Payload/Runner.app/Info.plist'))['CFBundleIdentifier'] ==
                    metadata['bundleIdentifier'], 'Packaged bundle metadata changed')
        archive.replace(output)
    with output.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    print(f'Validated unsigned iOS IPA: {output}')
    print(f'Metadata: {metadata}')
    print(f'SHA256: {digest}')
    print('Not installable until signed/provisioned with a legitimate Apple identity.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/ios/iphoneos/Runner.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ios/ipa/Triomi-iOS-Unsigned.ipa')
    args = parser.parse_args()
    package_ios(args.app, args.output)


if __name__ == '__main__':
    main()
