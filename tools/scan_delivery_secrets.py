"""Scan exact supplied credential/signing secret values, including ZIP members.

Only counts are emitted. Private inputs are never copied to the checkout.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
from urllib.parse import quote
import zipfile

from account_acceptance_relay import read_accounts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--artifact', type=Path, action='append', default=[])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    accounts = read_accounts(root.parent / 'Lk and LNS.txt')
    secrets = [v for a in accounts.values() for v in a.values()]
    signing = Path.home() / '.triomi/signing/signing.properties'
    for line in signing.read_text(encoding='utf8').splitlines():
        key, _, value = line.partition('=')
        if key.strip() in ('storePassword', 'keyPassword'):
            secrets.append(value.strip())
    needles = set()
    for value in secrets:
        if not value:
            continue
        for text in (value, quote(value, safe=''), json.dumps(value)[1:-1]):
            for encoding in ('utf8', 'utf-16-le', 'utf-16-be'):
                needles.add(text.encode(encoding))
        needles.add(base64.b64encode(value.encode('utf8')))
    # Basic auth is also an exact representation of the private input.
    for account in accounts.values():
        needles.add(base64.b64encode((account['account'] + ':' + account['password']).encode('utf8')))
    def scan_file(path):
        tail = b''
        overlap = max(map(len, needles))
        with path.open('rb') as source:
            while chunk := source.read(4 * 1024 * 1024):
                payload = tail + chunk
                if any(n in payload for n in needles):
                    return True
                tail = payload[-overlap:]
        return False
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode('utf8').split('\0')
    files = {root / n for n in names if n and (root / n).is_file()}
    files.update(p for p in (root.parent / '_tools').glob('C125*') if p.is_file())
    record = {'filesScanned': 0, 'filesWithCredentialOrSigningSecret': 0, 'artifacts': []}
    for path in files:
        record['filesScanned'] += 1
        record['filesWithCredentialOrSigningSecret'] += scan_file(path)
    for artifact in args.artifact:
        item = {'path': str(artifact.resolve()), 'membersScanned': 0, 'membersWithSecret': 0,
                'privateMaterialNames': 0, 'debugFiles': 0}
        if artifact.is_dir():
            members = [p for p in artifact.rglob('*') if p.is_file()]
            for path in members:
                item['membersScanned'] += 1
                item['membersWithSecret'] += scan_file(path)
                item['privateMaterialNames'] += path.suffix.lower() in ('.p12', '.jks', '.keystore') or path.name == 'signing.properties'
                item['debugFiles'] += path.suffix.lower() in ('.pdb', '.ilk', '.log')
        else:
            with zipfile.ZipFile(artifact) as archive:
                for info in archive.infolist():
                    if info.is_dir():
                        continue
                    item['membersScanned'] += 1
                    payload = archive.read(info)
                    item['membersWithSecret'] += any(n in payload for n in needles)
                    name = Path(info.filename)
                    item['privateMaterialNames'] += name.suffix.lower() in ('.p12', '.jks', '.keystore') or name.name == 'signing.properties'
                    item['debugFiles'] += name.suffix.lower() in ('.pdb', '.ilk', '.log')
        record['artifacts'].append(item)
    record['status'] = 'passed' if not record['filesWithCredentialOrSigningSecret'] and all(
        not r['membersWithSecret'] and not r['privateMaterialNames'] and not r['debugFiles'] for r in record['artifacts']) else 'failed'
    args.output.write_text(json.dumps(record, indent=2), encoding='utf8')
    print(json.dumps(record))
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
