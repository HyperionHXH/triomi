"""Four-port isolated UI evidence and separate real metadata audit, no Release.

All screenshot content is synthetic geometry. Public metadata preflight is
separate and its account/network failures are retained, never relabeled reading.
"""
from __future__ import annotations

import argparse
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import threading

from ios_integration_runner import run_integration
from run_ios_copy_acceptance import CopyCaptureHandler, collect_failure
from run_ios_visual_tour import (
    TourSession, VideoRecorder, sha256, timestamp, validate_device, validate_video,
)

ROOT = Path(__file__).resolve().parents[1]
CAPTURES = (
    '01_reader_ports_sources.png', '02_pica_settings.png',
    '03_picacomic_reader.png', '04_wnacg_reader.png',
    '05_jmcomic_reader.png', '06_ehentai_reader.png',
)


class ReaderPortSession(TourSession):
    expected_captures = CAPTURES
    allowed_captures = frozenset(CAPTURES)

    def __init__(self, device, output):
        super().__init__(device, output)
        self.manifest.update({
            'entrypoint': 'integration_test/ios_reader_ports_visual_test.dart',
            'required_captures': list(CAPTURES), 'extra_capture_names': [],
            'expected_captures': list(CAPTURES),
            'source_boundaries': {
                'content': 'Synthetic geometric PNGs and protocol fixtures at Dio adapter seam; production rules, registry, image processing and UI',
                'accounts': 'Fixture strings only, MemorySecureStore; zero real credentials or remote writes',
                'public_network': 'Forbidden in visual test; separate metadata audit has no images',
                'loopback': 'Capture-only POST; no content or account endpoint',
                'not_claimed': 'Real site images/reading, actual account or device installation',
            },
            'rules': [{
                'id': name,
                'sha256': sha256(ROOT / f'assets/rules/{name}-js.json'),
            } for name in ('picacomic', 'wnacg', 'jmcomic', 'ehentai')],
        })
        self.save()


def collect_metadata(device, output):
    app = ROOT / 'build/ios/iphonesimulator/Runner.app/Info.plist'
    with app.open('rb') as stream:
        bundle = plistlib.load(stream)['CFBundleIdentifier']
    result = subprocess.run(
        ['xcrun', 'simctl', 'get_app_container', device, bundle, 'data'],
        capture_output=True, text=True, check=True, timeout=30,
    )
    source = Path(result.stdout.strip()) / 'Documents/reader-ports'
    if not source.is_dir():
        raise ValueError('Metadata reports missing')
    shutil.copytree(source, output / 'reports')
    reports = [json.loads(p.read_text(encoding='utf-8'))
               for p in (output / 'reports').rglob('*-metadata.json')]
    expected = {'picacomic', 'wnacg', 'jmcomic', 'ehentai'}
    if len(reports) != 4 or {r.get('source') for r in reports} != expected:
        raise ValueError('Metadata report source set is incomplete or duplicated')
    return reports


def run_metadata(device, output):
    output.mkdir(parents=True, exist_ok=False)
    record = {'status': 'running', 'device': device, 'started_at': timestamp(),
              'scope': 'Real public metadata, NOT image/reader acceptance', 'errors': []}
    try:
        with (output / 'flutter.log').open('wb') as log:
            code = run_integration(
                shutil.which('flutter'), ROOT, device,
                'integration_test/ios_reader_ports_metadata_test.dart', [], log, 1200,
            )
        record['flutter_exit_code'] = code
        record['reports'] = collect_metadata(device, output)
        if code:
            record['errors'].append(f'Metadata audit exited {code}; raw failures retained')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        record['errors'].append(str(error))
    record.update(status='failed' if record['errors'] else 'completed', finished_at=timestamp())
    (output / 'manifest.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    return int(bool(record['errors']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--metadata', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin' or not shutil.which('flutter'):
        raise SystemExit('macOS and Flutter required')
    validate_device(args.device)
    output = args.output or ROOT / 'build/ios/reader-ports' / ('metadata' if args.metadata else 'visual')
    if args.metadata:
        return run_metadata(args.device, output)
    session = ReaderPortSession(args.device, output)
    recorder = VideoRecorder(args.device, output)
    server = None
    thread = None
    try:
        ffprobe = shutil.which('ffprobe')
        if not ffprobe:
            raise ValueError('ffprobe required')
        server = ThreadingHTTPServer(('127.0.0.1', 0), CopyCaptureHandler)
        server.session = session
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        recorder.start()
        with (output / 'flutter.log').open('wb') as log:
            code = run_integration(
                shutil.which('flutter'), ROOT, args.device, session.manifest['entrypoint'],
                [f'TRIOMI_READER_PORT_CAPTURE_URL=http://127.0.0.1:{server.server_port}'], log, 1200,
            )
        session.manifest['flutter_exit_code'] = code
        if code:
            session.fail(f'Production fixture UI exited {code}')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        session.fail(str(error))
    finally:
        try:
            recorder.stop()
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            session.fail(str(error))
        if server:
            server.shutdown()
            server.server_close()
        if thread:
            thread.join(timeout=5)
        try:
            session.validate_captures()
            session.manifest['recording'] = validate_video(recorder.path, shutil.which('ffprobe'))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            session.fail(str(error))
        if session.manifest['errors']:
            session.manifest['errors'].extend(collect_failure(args.device, output))
        session.manifest.update(status='failed' if session.manifest['errors'] else 'passed', finished_at=timestamp())
        session.save()
    return int(bool(session.manifest['errors']))


if __name__ == '__main__':
    raise SystemExit(main())
