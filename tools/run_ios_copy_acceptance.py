"""Real Copy API iOS acceptance: loopback is capture-only, never content.

Run with an explicit disposable booted simulator UDID. Evidence is never
replaced; logs, native captures and finalized video survive failing acceptance.
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading

from ios_integration_runner import run_integration
from run_ios_visual_tour import (
    CaptureError, TourSession, VideoRecorder, sha256, timestamp,
    validate_device, validate_video,
)

ROOT = Path(__file__).resolve().parents[1]
CAPTURES = (
    '01_copy_search.png', '02_copy_detail.png',
    '03_copy_old_reader.png', '04_copy_page_advanced.png',
    '05_copy_reader_settings.png', '06_copy_latest_reader.png',
    '07_copy_return.png', '08_copy_source_settings.png',
    '09_copy_native_comments.png', '10_copy_account_entry.png',
    '11_copy_next_chapter.png',
)


class CopySession(TourSession):
    expected_captures = CAPTURES
    allowed_captures = frozenset(CAPTURES)

    def __init__(self, device: str, output: Path):
        super().__init__(device, output)
        rule = ROOT / 'assets/rules/copymanga-js.json'
        self.manifest.update({
            'entrypoint': 'integration_test/ios_copy_live_test.dart',
            'required_captures': list(CAPTURES),
            'extra_capture_names': [], 'expected_captures': list(CAPTURES),
            'rule': {'path': str(rule.relative_to(ROOT)), 'sha256': sha256(rule)},
            'source_boundaries': {
                'content': 'Live public Copy HTTPS API and image CDN; no fixture or TLS override',
                'runtime': 'Production iOS WebKit JavaScript runtime and production HTTP',
                'accounts': 'Unauthenticated; isolated SQLite/preferences/MemorySecureStore; no account writes',
                'loopback': 'POST capture handshake only; all content routes rejected',
                'release_assets': 'Candidate asset SHA-256 recorded above; no asset replacement',
            },
        })
        self.save()


class CopyCaptureHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def reply(self, status, body):
        data = json.dumps(body).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != '/__tour/capture':
            self.reply(405, {'error': 'Capture-only host; content/mutations forbidden'})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 8192 or self.headers.get('Transfer-Encoding'):
                raise CaptureError('A bounded Content-Length is required')
            payload = json.loads(self.rfile.read(length).decode('utf-8'))
            capture = self.server.session.capture(payload)
        except (ValueError, UnicodeError) as error:
            self.server.session.fail(f'Capture rejected: {error}')
            self.reply(getattr(error, 'status', 400), {'error': str(error)})
            return
        self.reply(200, capture)

    def do_GET(self):
        self.reply(405, {'error': 'No fixture content is served by live acceptance'})

    do_PUT = do_GET
    do_DELETE = do_GET
    do_PATCH = do_GET

def collect_documents(device, output):
    import plistlib
    app = ROOT / 'build/ios/iphonesimulator/Runner.app'
    with (app / 'Info.plist').open('rb') as stream:
        bundle = plistlib.load(stream)['CFBundleIdentifier']
    result = subprocess.run(
        ['xcrun', 'simctl', 'get_app_container', device, bundle, 'data'],
        capture_output=True, text=True, check=True, timeout=30,
    )
    documents = Path(result.stdout.strip()) / 'Documents'
    target = output / 'documents'
    target.mkdir(exist_ok=True)
    for name in ('copy-live.json', 'manga-sources-live.json', 'manga-sources-live'):
        source = documents / name
        if source.is_dir():
            shutil.copytree(source, target / name)
        elif source.is_file():
            shutil.copy2(source, target / name)


def collect_failure(device, output):
    errors = []
    try:
        subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot',
                        str(output / 'failure.png')],
                       capture_output=True, check=True, timeout=30)
        with (output / 'simulator.log').open('wb') as log:
            subprocess.run(['xcrun', 'simctl', 'spawn', device, 'log', 'show',
                            '--last', '20m', '--style', 'compact',
                            '--predicate', 'process == "Runner"'],
                           stdout=log, stderr=subprocess.STDOUT, check=False, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        errors.append(f'Failure evidence collection failed: {error}')
    return errors


def run_audit(device, output):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Audit output directory must be empty')
    manifest = {'status': 'running', 'device': validate_device(device),
                'entrypoint': 'integration_test/ios_manga_sources_live_test.dart',
                'started_at': timestamp(), 'errors': []}
    code = 1
    try:
        flutter = shutil.which('flutter')
        if not flutter:
            raise ValueError('Flutter is required')
        with (output / 'flutter.log').open('wb') as log:
            code = run_integration(flutter, ROOT, device, manifest['entrypoint'],
                                   [], log, 90 * 60)
        if code:
            manifest['errors'].append(f'Source audit exited {code}')
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        manifest['errors'].append(str(error))
    finally:
        try:
            collect_documents(device, output)
            report = output / 'documents/manga-sources-live.json'
            if not report.is_file():
                raise ValueError('Per-source live audit report is missing')
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            manifest['errors'].append(f'Diagnostic collection failed: {error}')
        if manifest['errors']:
            manifest['errors'].extend(collect_failure(device, output))
        manifest.update(status='failed' if manifest['errors'] else 'passed',
                        finished_at=timestamp(), flutter_exit_code=code)
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    return int(bool(manifest['errors']))



def run_copy(session):
    server = None
    thread = None
    recorder = VideoRecorder(session.device, session.output)
    ffprobe = None
    try:
        if sys.platform != 'darwin':
            raise ValueError('Real iOS Copy acceptance requires macOS')
        session.manifest['device'] = validate_device(session.device)
        flutter, ffprobe = shutil.which('flutter'), shutil.which('ffprobe')
        if not flutter or not ffprobe:
            raise ValueError('Flutter and ffprobe are required on PATH')
        server = ThreadingHTTPServer(('127.0.0.1', 0), CopyCaptureHandler)
        server.session = session
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        session.manifest['capture_base_url'] = base
        session.save()
        recorder.start()
        with (session.output / 'flutter.log').open('wb') as log:
            code = run_integration(
                flutter, ROOT, session.device, session.manifest['entrypoint'],
                [f'TRIOMI_COPY_CAPTURE_URL={base}',
                 f'TRIOMI_COPY_RULE_SHA256={session.manifest["rule"]["sha256"]}'],
                log, 20 * 60,
            )
        session.manifest['flutter_exit_code'] = code
        if code:
            session.fail(f'Live Copy acceptance exited {code}; see flutter.log')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        session.fail(f'Live Copy execution failed: {error or type(error).__name__}')
    finally:
        try:
            recorder.stop()
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            session.fail(f'Recording finalization failed: {error}')
        if server is not None:
            server.shutdown()
            server.server_close()
            if thread is not None:
                thread.join(timeout=5)
        try:
            session.validate_captures()
        except (OSError, ValueError) as error:
            session.fail(str(error))
        try:
            if not ffprobe:
                raise ValueError('No recording decoder available')
            session.manifest['recording'] = validate_video(recorder.path, ffprobe)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            session.fail(f'Recording validation failed: {error}')
        try:
            collect_documents(session.device, session.output)
            report = json.loads((session.output / 'documents/copy-live.json').read_text(encoding='utf-8'))
            if report.get('status') != 'passed':
                raise ValueError('Production live Copy report did not pass')
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            session.fail(f'Live result collection failed: {error}')
        if session.manifest['errors']:
            for error in collect_failure(session.device, session.output):
                session.fail(error)
        session.manifest['finished_at'] = timestamp()
        session.manifest['status'] = 'failed' if session.manifest['errors'] else 'passed'
        session.save()
    for error in session.manifest['errors']:
        print(error, file=sys.stderr)
    return int(bool(session.manifest['errors']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--audit-sources', action='store_true',
                        help='Run the separate 17-source live production audit')
    args = parser.parse_args()
    if args.audit_sources:
        return run_audit(args.device, args.output or ROOT / 'build/ios/manga-sources-live')
    args.output = args.output or ROOT / 'build/ios/copy-live'
    session = CopySession(args.device, args.output)

    def interrupt(signum, frame):
        raise KeyboardInterrupt(f'Received signal {signum}')

    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        return run_copy(session)
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    raise SystemExit(main())
