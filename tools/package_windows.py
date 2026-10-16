"""Package one Windows release tree as ZIP, per-user MSI and integrity manifests."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid
import xml.etree.ElementTree as ET
import zipfile

from build_update_manifest import build_manifest

ROOT = Path(__file__).resolve().parents[1]
WIX_NS = 'http://wixtoolset.org/schemas/v4/wxs'
UI_NS = WIX_NS + '/ui'
# Permanent product family: never change this when publishing an upgrade.
UPGRADE_CODE = '57F8467B-9E75-4D87-9744-41DC82F8F54F'
IDENTITY = uuid.UUID(UPGRADE_CODE)


def msi_version(version: str, build: int) -> str:
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', version)
    if not match or not 1 <= build <= 65535:
        raise ValueError('MSI requires semantic major.minor.patch and build 1..65535')
    major, minor, _ = map(int, match.groups())
    if major > 255 or minor > 255:
        raise ValueError('MSI major and minor versions must be <=255')
    # MSI ignores a fourth field. The monotonically increasing Flutter build
    # belongs in the third field so 0.1.0+154 upgrades 0.1.0+153 correctly.
    return f'{major}.{minor}.{build}'


def stable_id(prefix: str, name: str) -> str:
    return prefix + uuid.uuid5(IDENTITY, name.casefold()).hex


def add(parent, name, **attrs):
    return ET.SubElement(parent, '{' + WIX_NS + '}' + name, attrs)


def installer_source(stage: Path, files: list[str], version: str, build: int,
                     icon: Path, license_rtf: Path) -> ET.ElementTree:
    ET.register_namespace('', WIX_NS)
    ET.register_namespace('ui', UI_NS)
    wix = ET.Element('{' + WIX_NS + '}Wix')
    package = add(wix, 'Package', Name='Triomi', Manufacturer='HyperionHXH',
                  Version=msi_version(version, build), UpgradeCode=UPGRADE_CODE,
                  ProductCode=str(uuid.uuid5(IDENTITY, f'product:{version}+{build}')),
                  Scope='perUser', Language='2052', InstallerVersion='500')
    add(package, 'MajorUpgrade', DowngradeErrorMessage='A newer Triomi version is already installed.',
        Schedule='afterInstallInitialize')
    add(package, 'MediaTemplate', EmbedCab='yes', CompressionLevel='high')
    add(package, 'Icon', Id='AppIcon', SourceFile=str(icon))
    add(package, 'Property', Id='ARPPRODUCTICON', Value='AppIcon')
    add(package, 'Property', Id='ARPURLINFOABOUT', Value='https://github.com/HyperionHXH/triomi')
    add(package, 'WixVariable', Id='WixUILicenseRtf', Value=str(license_rtf))
    ET.SubElement(package, '{' + UI_NS + '}WixUI', {'Id': 'WixUI_Minimal'})
    local = add(package, 'StandardDirectory', Id='LocalAppDataFolder')
    programs = add(local, 'Directory', Id='UserPrograms', Name='Programs')
    install = add(programs, 'Directory', Id='INSTALLFOLDER', Name='Triomi')
    directories = {'': install}
    component_ids = []
    # Build the directory tree independently of traversal order.
    for name in files:
        parent = Path(name).parent
        for directory in reversed([parent, *parent.parents]):
            relative = directory.as_posix()
            if relative == '.' or relative in directories:
                continue
            up = directory.parent.as_posix()
            directories[relative] = add(directories['' if up == '.' else up], 'Directory',
                                        Id=stable_id('D', relative), Name=directory.name)
        relative = '' if parent.as_posix() == '.' else parent.as_posix()
        cid = stable_id('C', name)
        component = add(directories[relative], 'Component', Id=cid,
                        Guid=str(uuid.uuid5(IDENTITY, 'component:' + name.casefold())), Bitness='always64')
        add(component, 'File', Id='AppExe' if name == 'triomi.exe' else stable_id('F', name),
            Source=str(stage / name), Name=Path(name).name)
        # A per-user registry keypath lets MSI repair a missing installation
        # without using or owning any application settings/database paths.
        add(component, 'RegistryValue', Root='HKCU', Key=r'Software\Triomi\Installer\Files',
            Name=cid, Type='integer', Value='1', KeyPath='yes')
        component_ids.append(cid)
    for directory, element in directories.items():
        cid = stable_id('R', directory)
        component = add(element, 'Component', Id=cid,
                        Guid=str(uuid.uuid5(IDENTITY, 'directory:' + directory.casefold())), Bitness='always64')
        add(component, 'RemoveFolder', Id=stable_id('Remove', directory), On='uninstall')
        add(component, 'RegistryValue', Root='HKCU', Key=r'Software\Triomi\Installer\Directories',
            Name=cid, Type='integer', Value='1', KeyPath='yes')
        component_ids.append(cid)
    menu = add(package, 'StandardDirectory', Id='ProgramMenuFolder')
    shortcut = add(menu, 'Component', Id='StartMenu', Guid=str(uuid.uuid5(IDENTITY, 'start-menu')), Bitness='always64')
    add(shortcut, 'Shortcut', Id='TriomiShortcut', Name='Triomi', Target='[INSTALLFOLDER]triomi.exe',
        WorkingDirectory='INSTALLFOLDER', Icon='AppIcon')
    add(shortcut, 'RegistryValue', Root='HKCU', Key=r'Software\Triomi\Installer',
        Name='StartMenu', Type='integer', Value='1', KeyPath='yes')
    component_ids.append('StartMenu')
    feature = add(package, 'Feature', Id='Application', Title='Triomi', Level='1')
    for cid in component_ids:
        add(feature, 'ComponentRef', Id=cid)
    tree = ET.ElementTree(wix)
    ET.indent(tree, space='  ')
    return tree


def package_windows(bundle: Path, output: Path, version: str, build: int, dotnet: str):
    msi_version(version, build)
    if bundle.resolve() == output.resolve() or bundle.resolve() in output.resolve().parents:
        raise ValueError('Output must be outside the application bundle')
    files = sorted(p.relative_to(bundle).as_posix() for p in bundle.rglob('*') if p.is_file())
    if any(p.is_symlink() for p in bundle.rglob('*')):
        raise ValueError('Symlinks are not permitted in a Windows release')
    if any(Path(name).suffix.lower() in {'.pdb', '.ilk', '.log', '.p12', '.jks', '.keystore'}
           or Path(name).name.casefold() == 'signing.properties' for name in files):
        raise ValueError('Release contains debug files or private signing material')
    output.mkdir(parents=True, exist_ok=True)
    bundle_zip = output / 'triomi-windows.zip'
    with zipfile.ZipFile(bundle_zip, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in files:
            archive.write(bundle / name, name)
    manifest = build_manifest(bundle_zip, version, build)
    (output / 'triomi-windows.update.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    work = ROOT / 'build/windows-installer'
    work.mkdir(parents=True, exist_ok=True)
    license_rtf = work / 'license.rtf'
    text = (ROOT / 'LICENSE').read_text(encoding='utf-8')
    text = text.replace('\\', r'\\').replace('{', r'\{').replace('}', r'\}').replace('\n', r'\par ' + '\n')
    license_rtf.write_text(r'{\rtf1\ansi\deff0 {\fonttbl {\f0 Consolas;}}\f0\fs16 ' + text + '}', encoding='ascii')
    source = work / 'Triomi.wxs'
    installer_source(bundle.resolve(), files, version, build,
                     ROOT / 'windows/runner/resources/app_icon.ico', license_rtf).write(
                         source, encoding='utf-8', xml_declaration=True)
    subprocess.run([dotnet, 'tool', 'run', 'wix', '--', 'build', str(source), '-arch', 'x64',
                    '-ext', 'WixToolset.UI.wixext/6.0.2', '-culture', 'zh-CN',
                    '-intermediatefolder', str(work / 'obj'),
                    '-out', str(output / 'triomi-windows.msi'), '-pdbtype', 'none'], cwd=ROOT, check=True)
    names = ['triomi-windows.zip', 'triomi-windows.msi', 'triomi-windows.update.json']
    checksums = []
    for name in names:
        with (output / name).open('rb') as stream:
            checksums.append(f'{hashlib.file_digest(stream, "sha256").hexdigest()}  {name}\n')
    (output / 'SHA256SUMS.txt').write_text(''.join(checksums), encoding='ascii')
    print(f'Windows ZIP + MSI ready: {output} ({len(files)} application files; MSI {msi_version(version, build)})')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=ROOT / 'build/windows/x64/runner/Release')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/release')
    parser.add_argument('--dotnet', default='dotnet')
    args = parser.parse_args()
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                        (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
    if not version:
        parser.error('pubspec.yaml must contain version: major.minor.patch+build')
    package_windows(args.bundle, args.output.resolve(), version[1], int(version[2]), args.dotnet)


if __name__ == '__main__':
    main()
