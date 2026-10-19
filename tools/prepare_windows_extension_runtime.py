"""Assemble Triomi's private Windows extension runtime (requires a Windows x64 JDK 21).

Only build tooling uses JAVA_HOME. The shipped image contains its own Java runtime.
Cache files are always checked against the pins, including explicitly seeded files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SERVER_VERSION = 'v2.4.2366'
SERVER_NAME = f'Suwayomi-Server-{SERVER_VERSION}.jar'
SERVER_URL = f'https://github.com/Suwayomi/Suwayomi-Server/releases/download/{SERVER_VERSION}/{SERVER_NAME}'
SERVER_SHA256 = 'af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd'
APKSIG_NAME = 'apksig-8.13.0.jar'
APKSIG_URL = 'https://dl.google.com/dl/android/maven2/com/android/tools/build/apksig/8.13.0/' + APKSIG_NAME
APKSIG_SHA256 = 'c070ed1394629d74641aa0906f60b2ffa1ee77e6366a1f93437f59717b1aeb89'
LICENSE_URL = f'https://raw.githubusercontent.com/Suwayomi/Suwayomi-Server/{SERVER_VERSION}/LICENSE'
LICENSE_SHA256 = '3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04'
MODULES = ('java.se,jdk.unsupported,jdk.crypto.ec,jdk.zipfs,jdk.charsets,'
           'jdk.localedata,jdk.net,jdk.management,jdk.security.auth,'
           'jdk.httpserver,jdk.naming.dns,jdk.naming.rmi')
SERVER_PART_BYTES = 64 * 1024 * 1024


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def cached(cache: Path, name: str, url: str, expected: str,
           seed: Path | None = None) -> Path:
    destination = cache / name
    if seed is not None:
        if sha256(seed) != expected:
            raise ValueError(f'Incorrect checksum for seeded {name}')
        if seed.resolve() != destination.resolve():
            shutil.copyfile(seed, destination)
    if destination.exists():
        if sha256(destination) != expected:
            raise ValueError(f'Incorrect checksum for cached {name}; remove it before retrying')
        return destination
    temporary = destination.with_suffix(destination.suffix + '.download')
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'Triomi-runtime-packager'})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        if sha256(temporary) != expected:
            raise ValueError(f'Incorrect download checksum for {name}')
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def extract_notices(jar: Path, target: Path) -> list[dict[str, str]]:
    """Retain every notice, including duplicate names in upstream's fat JAR."""
    target.mkdir(parents=True)
    records = []
    with zipfile.ZipFile(jar) as archive:
        for entry in archive.infolist():
            if entry.is_dir() or not any(
                part in entry.filename.lower() for part in ('license', 'notice', 'copying')
            ) or entry.filename.endswith('.class'):
                continue
            filename = f'{len(records):04d}.txt'
            with archive.open(entry) as source, (target / filename).open('wb') as output:
                shutil.copyfileobj(source, output)
            records.append({'entry': entry.filename, 'file': filename})
    (target / 'index.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf-8')
    return records


def split_server(server: Path, stage: Path) -> list[dict[str, str | int]]:
    # Keep the updater's existing 128MiB per-member ceiling unchanged. Concatenating
    # these bounded chunks reproduces the exact, unmodified, hash-pinned JAR.
    parts = []
    with server.open('rb') as source:
        remaining = server.stat().st_size
        while remaining:
            name = f'suwayomi.jar.part{len(parts)}'
            size = min(remaining, SERVER_PART_BYTES)
            digest = hashlib.sha256()
            with (stage / name).open('wb') as target:
                unwritten = size
                while unwritten:
                    chunk = source.read(min(unwritten, 1024 * 1024))
                    if not chunk:
                        raise ValueError('Truncated server cache while splitting')
                    target.write(chunk)
                    digest.update(chunk)
                    unwritten -= len(chunk)
            parts.append({'file': name, 'size': size, 'sha256': digest.hexdigest()})
            remaining -= size
    return parts


def prepare(args: argparse.Namespace) -> None:
    if os.name != 'nt':
        raise ValueError('Build the Windows runtime on Windows with an x64 JDK 21')
    if not args.java_home:
        raise ValueError('Supply --java-home or set JAVA_HOME to an x64 JDK 21')
    java_home = Path(args.java_home).resolve()
    release = (java_home / 'release').read_text(encoding='utf-8')
    if not re.search(r'^JAVA_VERSION="21(?:[.\+"]|$)', release, re.MULTILINE):
        raise ValueError('The runtime must be built using JDK 21')
    if not re.search(r'^OS_ARCH="(?:amd64|x86_64)"$', release, re.MULTILINE):
        raise ValueError('The runtime requires an x64 JDK')
    for tool in ('java.exe', 'javac.exe', 'jar.exe', 'jlink.exe'):
        if not (java_home / 'bin' / tool).is_file():
            raise ValueError(f'Missing JDK tool: {tool}')
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    server = cached(cache, SERVER_NAME, SERVER_URL, SERVER_SHA256, args.server_jar)
    apksig = cached(cache, APKSIG_NAME, APKSIG_URL, APKSIG_SHA256, args.apksig_jar)
    license_file = cached(cache, 'Suwayomi-LICENSE.txt', LICENSE_URL, LICENSE_SHA256)
    output = args.output.resolve()
    if output.name != 'extension-runtime':
        raise ValueError('Output directory must be named extension-runtime (never a data root)')
    if output.exists() and any(output.iterdir()) and not (output / 'provenance.json').is_file():
        raise ValueError('Refusing to replace a non-owned runtime directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='extension-runtime-build-', dir=output.parent) as work_name:
        work = Path(work_name)
        stage = work / 'extension-runtime'
        stage.mkdir()
        subprocess.run([str(java_home / 'bin/jlink.exe'), '--module-path', str(java_home / 'jmods'),
                        '--add-modules', MODULES, '--strip-debug', '--no-header-files',
                        '--no-man-pages', '--compress=2', '--output', str(stage / 'java')], check=True)
        # MSI/update manifests intentionally reject symlinks. Materialize any JDK
        # legal-document links while preserving their content in the image.
        for path in (stage / 'java').rglob('*'):
            if path.is_symlink():
                content = path.read_bytes()
                path.unlink()
                path.write_bytes(content)
        classes = work / 'classes'
        classes.mkdir()
        subprocess.run([str(java_home / 'bin/javac.exe'), '--release', '21', '-encoding', 'UTF-8',
                        '-cp', os.pathsep.join((str(server), str(apksig))), '-d', str(classes),
                        str(ROOT / 'tools/desktop/ApkInspector.java')], check=True)
        inspector = stage / 'triomi-apk-inspector.jar'
        subprocess.run([str(java_home / 'bin/jar.exe'), '--create', '--file', str(inspector),
                        '-C', str(classes), '.'], check=True)
        parts = split_server(server, stage)
        shutil.copyfile(apksig, stage / 'apksig.jar')
        legal = stage / 'legal'
        legal.mkdir()
        shutil.copyfile(license_file, legal / 'Suwayomi-MPL-2.0.txt')
        extract_notices(server, legal / 'suwayomi-bundled')
        extract_notices(apksig, legal / 'apksig')
        # jlink retains each included module's third-party notices under java/legal.
        (legal / 'SOURCES.txt').write_text(
            f'Suwayomi Server {SERVER_VERSION} is unmodified, MPL-2.0.\n'
            f'Corresponding source: https://github.com/Suwayomi/Suwayomi-Server/tree/{SERVER_VERSION}\n'
            'apksig 8.13.0: Apache-2.0, Android Open Source Project.\n'
            'Source: https://android.googlesource.com/platform/tools/apksig/\n'
            'JRE module licenses/notices: ../java/legal; vendor/version: ../java/release.\n'
            'OpenJDK corresponding sources: https://github.com/adoptium/temurin21-binaries/releases\n'
            'Triomi inspector source: tools/desktop/ApkInspector.java in the matching Triomi release.\n',
            encoding='utf-8')
        provenance = {
            'format': 1,
            'suwayomi': {'version': SERVER_VERSION, 'url': SERVER_URL, 'sha256': SERVER_SHA256,
                         'size': server.stat().st_size, 'parts': parts},
            'apksig': {'version': '8.13.0', 'url': APKSIG_URL, 'sha256': APKSIG_SHA256},
            'suwayomiLicense': {'url': LICENSE_URL, 'sha256': LICENSE_SHA256},
            'javaRelease': release,
            'javaModules': MODULES.split(','),
            'inspectorSourceSha256': sha256(ROOT / 'tools/desktop/ApkInspector.java'),
            'inspectorJarSha256': sha256(inspector),
            'diskOverhead': {
                'serverInstallChunksBytes': server.stat().st_size,
                'serverBuildCacheBytes': server.stat().st_size,
                'serverDataRootAssemblyBytes': server.stat().st_size,
                'serverAssemblyTemporaryPeakBytes': 2 * server.stat().st_size,
                'note': 'Install chunks remain immutable. The app stream-assembles an independently '
                        'hash-verified JAR in its data root; atomic replacement can temporarily retain '
                        'both the previous JAR and its replacement. Build cache is not distributed.',
            },
        }
        (stage / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
        # Only replace the immutable install payload, never the separately supplied
        # application data root. Old payload remains intact until assembly succeeds.
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(stage), str(output))
    print(f'Windows extension runtime ready: {output}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java-home', default=os.environ.get('JAVA_HOME'), help='Windows x64 JDK 21')
    parser.add_argument('--cache', type=Path, default=ROOT / 'build/extension-runtime-cache')
    parser.add_argument('--output', type=Path,
                        default=ROOT / 'build/windows/x64/runner/Release/extension-runtime')
    parser.add_argument('--server-jar', type=Path, help='Seed cache from a checksum-verified upstream JAR')
    parser.add_argument('--apksig-jar', type=Path, help='Seed cache from a checksum-verified apksig JAR')
    args = parser.parse_args()
    try:
        prepare(args)
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Runtime preparation failed: {error}\n')


if __name__ == '__main__':
    main()
