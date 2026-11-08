"""Prefetch pinned iOS SQLite assets through GitHub's official asset API.

The package hook downloads browser release URLs without checking HTTP status;
HTTP504 bodies therefore surface as hash errors. Keep its exact pinned hashes
and shared-cache layout so the unmodified hook independently verifies them again.
"""
import hashlib
import json
from pathlib import Path
import re
import tempfile
from urllib.parse import urlparse
from urllib.request import Request, urlopen, url2pathname

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('libsqlite3.arm64.ios.dylib', 'libsqlite3.arm64.ios_sim.dylib')
MAX_BYTES = 8 * 1024 * 1024


def fetch(url, *, binary=False):
    if urlparse(url).hostname != 'api.github.com':
        raise ValueError('SQLite metadata and assets must use the official GitHub API')
    request = Request(url, headers={
        'Accept': 'application/octet-stream' if binary else 'application/vnd.github+json',
        'User-Agent': 'Triomi-pinned-sqlite-prefetch',
    })
    with urlopen(request, timeout=60) as response:
        payload = response.read(MAX_BYTES + 1)
    if len(payload) > MAX_BYTES:
        raise ValueError('SQLite asset exceeds the bounded download size')
    return payload


def publish(payload, expected, destination):
    if hashlib.sha256(payload).hexdigest() != expected:
        raise ValueError('SQLite asset does not match the package-pinned SHA-256')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(payload)
            stream.flush()
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    config = ROOT / '.dart_tool/package_config.json'
    package = next(p for p in json.loads(config.read_text(encoding='utf-8'))['packages']
                   if p['name'] == 'sqlite3')
    uri = urlparse(package['rootUri'])
    package_root = Path(url2pathname(uri.path)) if uri.scheme == 'file' else config.parent / package['rootUri']
    pins = (package_root / 'lib/src/hook/asset_hashes.dart').read_text(encoding='utf-8')
    tag = re.search(r"releaseTag = '([^']+)'", pins).group(1)
    hashes = dict(re.findall(r"'([^']+)': '([a-f0-9]{64})'", pins))
    release = json.loads(fetch('https://api.github.com/repos/simolus3/sqlite3.dart/releases/tags/' + tag))
    for name in NAMES:
        expected = hashes[name]
        asset = next(a for a in release['assets'] if a['name'] == name)
        if asset.get('digest') != 'sha256:' + expected or not 0 < asset['size'] <= MAX_BYTES:
            raise ValueError('Official SQLite release metadata differs from the pinned package')
        destination = ROOT / '.dart_tool/hooks_runner/shared/sqlite3/build' / ('download-' + expected[:8]) / 'libsqlite3.dylib'
        if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == expected:
            print('Verified existing pinned SQLite asset: ' + name)
            continue
        payload = fetch(asset['url'], binary=True)
        if len(payload) != asset['size']:
            raise ValueError('Official SQLite asset size differs from release metadata')
        publish(payload, expected, destination)
        print('Verified official SQLite asset: ' + name + ' SHA256=' + expected)


if __name__ == '__main__':
    main()
