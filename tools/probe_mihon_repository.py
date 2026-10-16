"""Read-only network evidence for the user's Mihon extension repository.

This inspects a real APK; it does not install or execute it and is not an APK
runtime. Keep that boundary explicit when reporting the result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import zipfile
from datetime import datetime, timezone

REPO = 'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/index.json'
ROOT = Path(__file__).resolve().parents[1]


class HttpsRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Repository redirect requires HTTPS')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, limit):
    if not url.startswith('https://'):
        raise ValueError('Repository downloads require HTTPS')
    with urllib.request.build_opener(HttpsRedirects()).open(url, timeout=40) as response:
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError('Repository download exceeds size limit')
        return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default=REPO)
    parser.add_argument('--extension', default='MangaDex')
    parser.add_argument('--apksigner', default=r'C:\Android\Sdk\build-tools\36.0.0\apksigner.bat')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/delivery/evidence/C109-mihon-repository.json')
    parser.add_argument('--apk-output', type=Path)
    parser.add_argument('--index-output', type=Path)
    args = parser.parse_args()
    raw = fetch(args.url, 8 * 1024 * 1024)
    index = json.loads(raw)
    extensions = index['extensionList']['extensions']
    entry = next(e for e in extensions if e['name'] == args.extension)
    apk = fetch(entry['resources']['apkUrl'], 64 * 1024 * 1024)
    with tempfile.TemporaryDirectory(prefix='triomi-repo-') as directory:
        path = Path(directory) / 'extension.apk'
        path.write_bytes(apk)
        env = dict(os.environ)
        env.setdefault('JAVA_HOME', r'C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot')
        verify = subprocess.run(
            [args.apksigner, 'verify', '--verbose', '--print-certs', str(path)],
            env=env, capture_output=True, text=True, encoding='utf-8', errors='replace',
            check=True,
        )
        fingerprint = re.search(r'certificate SHA-256 digest: ([0-9a-fA-F]+)', verify.stdout)
        if not fingerprint:
            raise ValueError('APK has no verified signer fingerprint')
        with zipfile.ZipFile(path) as archive:
            dex_files = [n for n in archive.namelist() if re.fullmatch(r'classes\d*\.dex', n)]
            if not dex_files or 'AndroidManifest.xml' not in archive.namelist():
                raise ValueError('Downloaded artifact is not an Android extension APK')
    record = {
        'recordedAt': datetime.now(timezone.utc).isoformat(),
        'repositoryUrl': args.url, 'repositoryName': index['name'],
        'indexBytes': len(raw), 'indexSha256': hashlib.sha256(raw).hexdigest(),
        'extensionCount': len(extensions),
        'sourceCount': sum(len(e['sources']) for e in extensions),
        'chineseExtensionCount': sum(any(s['language'] == 'zh' for s in e['sources']) for e in extensions),
        'selectedExtension': entry['name'], 'packageName': entry['packageName'],
        'version': entry['versionName'], 'extensionLib': entry['extensionLib'],
        'apkUrl': entry['resources']['apkUrl'], 'apkBytes': len(apk),
        'apkSha256': hashlib.sha256(apk).hexdigest(),
        'apkSignerSha256': fingerprint[1].lower(),
        'repositorySigningKey': index['signingKey'],
        'signerMatchesRepositoryKey': fingerprint[1].lower() == index['signingKey'].lower(),
        'dexFiles': dex_files,
        'verification': verify.stdout,
        'apkSignatureVerification': 'passed',
        'triomiApkExecution': 'not tested by this metadata-only probe',
    }
    output = args.output
    output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if args.apk_output:
        args.apk_output.write_bytes(apk)
    if args.index_output:
        args.index_output.write_bytes(raw)
    print(json.dumps({k: record[k] for k in ['extensionCount', 'sourceCount', 'chineseExtensionCount', 'apkBytes', 'apkSignerSha256', 'signerMatchesRepositoryKey']}, indent=2))


if __name__ == '__main__':
    main()
