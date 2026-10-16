import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def build_manifest(bundle: Path, version: str, version_code: int) -> dict:
    if version_code < 1 or not version:
        raise ValueError('A real release version and positive build code are required')
    files = {}
    folded = set()
    total = 0
    with zipfile.ZipFile(bundle) as archive:
        if len(archive.infolist()) > 10000:
            raise ValueError('Bundle has too many entries')
        for entry in archive.infolist():
            name = entry.filename
            parts = name.split('/')
            if (not name or name.startswith('/') or '\\' in name or ':' in name
                    or any(part in {'.', '..'} or part.endswith(('.', ' ')) for part in parts if part)
                    or any(not part for part in parts[:-1])
                    or name.casefold() in folded
                    or ((entry.external_attr >> 16) & 0o170000) == 0o120000):
                raise ValueError('Bundle has unsafe, duplicate, or symlink member')
            folded.add(name.casefold())
            if entry.is_dir():
                continue
            total += entry.file_size
            if entry.file_size > 128 * 1024 * 1024 or total > 1024 * 1024 * 1024:
                raise ValueError('Bundle exceeds updater limits')
            digest = hashlib.sha256()
            size = 0
            with archive.open(entry) as source:
                while chunk := source.read(1024 * 1024):
                    size += len(chunk)
                    digest.update(chunk)
            if size != entry.file_size:
                raise ValueError('Bundle has truncated member')
            files[name] = {'size': size, 'sha256': digest.hexdigest()}
    if not {'triomi.exe', 'flutter_windows.dll'} <= files.keys():
        raise ValueError('Bundle lacks Windows application files')
    with bundle.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    return {'platform': 'windows', 'packageName': 'io.github.hyperionhxh.triomi',
            'version': version, 'versionCode': version_code, 'sha256': digest, 'files': files}


def main() -> None:
    parser = argparse.ArgumentParser(description='Build bounded Windows update integrity manifest; this is not a publisher signature.')
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--version-code', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    manifest = build_manifest(args.bundle, args.version, args.version_code)
    args.output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Windows update manifest: {len(manifest["files"])} verified members')


if __name__ == '__main__':
    main()
