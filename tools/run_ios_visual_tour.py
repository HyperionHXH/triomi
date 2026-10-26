"""Capture the production iOS UI tour using an isolated loopback fixture.

Run on macOS with an explicitly selected, already booted iOS Simulator UDID.
The output directory must be empty; existing evidence is never overwritten.
The fixture only permits read-only media/content requests and capture handshakes.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from http.server import ThreadingHTTPServer
import json
import math
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
from urllib.parse import urlparse
import zlib

from dev_fixture_server import Handler
from ios_integration_runner import run_integration


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_CAPTURES = (
    '01_home_shelf.png',
    '02_source_rules.png',
    '03_search_explore.png',
    '04_novel_reader.png',
    '05_manga_reader.png',
    '06_anime_player_danmaku.png',
    '07_downloads_settings.png',
)
EXTRA_CAPTURES = (
    '01_manga_shelf.png', '01_novel_shelf.png',
    '01_novel_downloaded_filter.png',
    '02_anime_sources.png', '02_manga_sources.png', '02_novel_sources.png',
    '02_source_import.png', '02_kazumi_repositories.png', '02_mihon_fallback.png',
    '03_discover.png', '03_detail.png',
    '04_novel_reader_menu.png', '04_novel_reader_settings.png',
    '04_novel_catalog.png', '04_novel_reading_options.png', '04_novel_scroll.png',
    '05_manga_reader_controls.png', '06_anime_player_controls.png',
    '06_anime_player_settings.png',
    '06_anime_player_speed.png', '06_anime_player_ratio.png', '06_anime_player_buffer.png',
    '06_danmaku_sources.png', '06_danmaku_bilibili_pool.png',
    '06_danmaku_animeko_pool.png', '06_danmaku_gamer_pool.png',
    '06_danmaku_offsets.png', '06_danmaku_display_settings.png',
    '07_profile.png', '07_settings.png', '07_anime_settings.png',
    '07_manga_settings.png', '07_novel_settings.png', '07_webdav.png',
    '07_tracking.png', '07_lk_account.png', '07_lns_account.png',
    '07_backup.png', '07_history.png', '07_danmaku_settings.png',
    '07_cache_management.png', '07_cache_memory_confirmation.png',
    '07_cache_http_confirmation.png',
    '07_cache_retained_content.png', '07_danmaku_shield_rules.png',
    '07_settings_large_text.png',
)
# Keep the original seven public evidence filenames stable, while requiring
# every agreed production surface for a complete latest-mainline tour.
EXPECTED_CAPTURES = REQUIRED_CAPTURES + EXTRA_CAPTURES
ALLOWED_CAPTURES = frozenset(EXPECTED_CAPTURES)
CAPTURE_NAME = re.compile(r'[0-9]{2}_[a-z0-9]+(?:_[a-z0-9]+)*\.png\Z')
UDID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z')
TOUR_TIMEOUT_SECONDS = 18 * 60


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def png_metadata(path: Path) -> dict:
    with path.open('rb') as stream:
        header = stream.read(33)
    if (len(header) != 33 or header[:8] != b'\x89PNG\r\n\x1a\n'
            or header[8:16] != b'\x00\x00\x00\rIHDR'
            or struct.unpack('>I', header[29:33])[0]
            != zlib.crc32(header[12:29]) & 0xffffffff):
        raise ValueError(f'Invalid PNG dimension header: {path.name}')
    width, height = struct.unpack('>II', header[16:24])
    if width <= 0 or height <= 0 or path.stat().st_size <= 33:
        raise ValueError(f'Empty PNG screenshot: {path.name}')
    return {
        'width': width, 'height': height,
        'bytes': path.stat().st_size, 'sha256': sha256(path),
    }


def validate_device(device: str) -> dict:
    if not UDID.fullmatch(device):
        raise ValueError('--device must be an explicit iOS Simulator UDID, never booted/name')
    try:
        result = subprocess.run(
            ['xcrun', 'simctl', 'getenv', device, 'SIMULATOR_UDID'],
            capture_output=True,
            text=True,
            check=True,
            timeout=15,
        )
    except subprocess.TimeoutExpired as error:
        raise ValueError(f'Selected simulator did not answer its boot-state probe: {device}') from error
    actual = result.stdout.strip()
    if actual.lower() != device.lower():
        raise ValueError(f'Selected simulator is not running with the requested UDID: {device}')
    return {'udid': actual}


class CaptureError(ValueError):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


class TourSession:
    def __init__(self, device: str, output: Path):
        self.device = device
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        if any(self.output.iterdir()):
            raise ValueError(f'Output directory must be empty: {self.output}')
        self.screenshots = self.output / 'screenshots'
        self.screenshots.mkdir()
        self.lock = threading.RLock()
        self.manifest = {
            'schema_version': 1,
            'status': 'running',
            'started_at': timestamp(),
            'device': {'udid': device},
            'entrypoint': 'integration_test/ios_visual_tour_test.dart',
            'source_boundaries': {
                'bind_address': '127.0.0.1',
                'port': 'ephemeral',
                'content': 'Repository-only deterministic image, novel, video and independent danmaku pool fixtures; production session/rendering, not live upstream matching',
                'accounts': 'Unauthenticated isolated test database/preferences/MemorySecureStore',
                'mutations': 'Only POST /__tour/capture; fixture account and WebDAV writes are disabled',
                'release_assets': 'Tour fixtures are host-only; the production IPA is built before the tour',
            },
            'required_captures': list(REQUIRED_CAPTURES),
            'extra_capture_names': list(EXTRA_CAPTURES),
            'expected_captures': list(EXPECTED_CAPTURES),
            'captures': [],
            'errors': [],
        }
        self.save()

    def save(self) -> None:
        with self.lock:
            temporary = self.output / '.manifest.json.tmp'
            temporary.write_text(
                json.dumps(self.manifest, ensure_ascii=False, indent=2) + '\n',
                encoding='utf-8',
            )
            temporary.replace(self.output / 'manifest.json')

    def fail(self, message: str) -> None:
        with self.lock:
            self.manifest['errors'].append(message)
            self.save()

    def capture(self, payload: object) -> dict:
        if not isinstance(payload, dict):
            raise CaptureError('Capture body must be a JSON object')
        name = payload.get('name')
        if not isinstance(name, str) or not CAPTURE_NAME.fullmatch(name):
            raise CaptureError('Capture name must be a PNG basename without paths')
        if name not in ALLOWED_CAPTURES:
            raise CaptureError(f'Unknown capture name: {name}')
        for field in ('route', 'description'):
            if field in payload and (
                not isinstance(payload[field], str) or len(payload[field]) > 2048
            ):
                raise CaptureError(f'{field} must be a string of at most 2048 characters')
        with self.lock:
            captures = self.manifest['captures']
            if any(item['name'] == name for item in captures):
                raise CaptureError(f'Duplicate capture name: {name}', 409)
            target = self.screenshots / name
            if target.exists():
                raise CaptureError(f'Capture file already exists: {name}', 409)
            try:
                subprocess.run(
                    ['xcrun', 'simctl', 'io', self.device, 'screenshot', '--type=png', str(target)],
                    check=True, capture_output=True, text=True, timeout=45,
                )
                metadata = png_metadata(target)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                diagnostic = getattr(error, 'stderr', None) or str(error)
                raise CaptureError(f'Screenshot failed for {name}: {diagnostic}', 500) from error
            if any(item['sha256'] == metadata['sha256'] for item in captures):
                raise CaptureError(f'Duplicate screenshot frame: {name}', 409)
            capture = {
                'sequence': len(captures) + 1,
                'name': name,
                'path': f'screenshots/{name}',
                'captured_at': timestamp(),
                **metadata,
                **{field: payload[field] for field in ('route', 'description') if field in payload},
            }
            captures.append(capture)
            self.save()
            return capture

    def validate_captures(self) -> None:
        with self.lock:
            captures = self.manifest['captures']
            names = [item['name'] for item in captures]
            missing = sorted(set(EXPECTED_CAPTURES) - set(names))
            if missing:
                raise ValueError(f'Missing required tour captures: {", ".join(missing)}')
            if len(names) != len(set(names)):
                raise ValueError('Duplicate capture names in manifest')
            if len({item['sha256'] for item in captures}) != len(captures):
                raise ValueError('Duplicate screenshot frames in manifest')
            if {item.name for item in self.screenshots.iterdir()} != set(names):
                raise ValueError('Screenshot files do not match the successful capture manifest')
            for capture in captures:
                actual = png_metadata(self.screenshots / capture['name'])
                if any(capture[key] != value for key, value in actual.items()):
                    raise ValueError(f'Screenshot changed after capture: {capture["name"]}')


class TourHandler(Handler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def reply(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):  # noqa: N802
        if self.path != '/__tour/capture':
            self.deny_mutation()
            return
        try:
            if self.headers.get_content_type() != 'application/json':
                raise CaptureError('Capture requires application/json', 415)
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError as error:
                raise CaptureError('Invalid capture Content-Length') from error
            if not 0 < length <= 8192:
                raise CaptureError('Capture body must contain 1-8192 bytes')
            try:
                payload = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeError) as error:
                raise CaptureError('Invalid capture JSON') from error
            capture = self.server.session.capture(payload)
        except CaptureError as error:
            self.server.session.fail(str(error))
            self.reply(error.status, {'error': str(error)})
            return
        self.reply(200, capture)

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path == '/__tour/manga.png':
            self._send((ROOT / 'tools/fixture_media/ui-tour-manga.png').read_bytes(), 'image/png')
            return
        if (path in ('/list', '/search', '/calendar', '/anime/list', '/anime/search', '/novel/list',
                     '/api/v2/search/episodes')
                or path.startswith(('/manga/', '/chapter/', '/img/cover/', '/img/page/',
                                    '/anime/', '/play/', '/novel/', '/novelchapters/',
                                    '/novelread/', '/danmaku/', '/api/v2/comment/'))
                or path == '/video/sample.mp4'):
            super().do_GET()
            return
        self.reply(404, {'error': 'Unknown read-only tour fixture endpoint'})

    def deny_mutation(self):
        self.reply(405, {'error': 'Tour fixtures only permit read-only content and explicit captures'})

    do_PUT = deny_mutation
    do_PATCH = deny_mutation
    do_DELETE = deny_mutation
    do_MKCOL = deny_mutation
    do_PROPFIND = deny_mutation


class TourServer(ThreadingHTTPServer):
    def __init__(self, session: TourSession):
        self.session = session
        super().__init__(('127.0.0.1', 0), TourHandler)


class VideoRecorder:
    def __init__(self, device: str, output: Path):
        self.path = output / 'ios_ui_tour.mp4'
        self.log_path = output / 'recording.log'
        self.device = device
        self.process = None
        self.log = None

    def start(self) -> None:
        self.log = self.log_path.open('wb')
        try:
            self.process = subprocess.Popen(
                ['xcrun', 'simctl', 'io', self.device, 'recordVideo', '--codec=h264', str(self.path)],
                stdout=self.log, stderr=subprocess.STDOUT,
            )
        except BaseException:
            self.log.close()
            raise

    def stop(self) -> None:
        if self.process is None:
            return
        try:
            if self.process.poll() is not None:
                raise RuntimeError(f'Simulator recorder exited before the tour finished: {self.process.returncode}')
            self.process.send_signal(signal.SIGINT)
            try:
                code = self.process.wait(timeout=30)
            except subprocess.TimeoutExpired as error:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
                raise RuntimeError('Recorder did not finalize after SIGINT; child-only termination was required') from error
            if code not in (0, -signal.SIGINT):
                raise RuntimeError(f'Simulator recorder failed while finalizing: exit {code}')
        finally:
            self.log.close()


def validate_video(path: Path, ffprobe: str) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError('Simulator recording is missing or empty')
    result = subprocess.run(
        [ffprobe, '-v', 'error', '-select_streams', 'v:0', '-count_frames',
         '-show_entries', 'stream=codec_name,width,height,nb_read_frames:format=duration',
         '-of', 'json', str(path)],
        capture_output=True, text=True, check=False, timeout=120,
    )
    if result.returncode != 0:
        raise ValueError(f'Recording is not decodable: {result.stderr.strip()}')
    if result.stderr.strip():
        raise ValueError(f'Recording decode errors: {result.stderr.strip()}')
    probe = json.loads(result.stdout)
    streams = probe.get('streams', [])
    duration = float(probe.get('format', {}).get('duration', 'nan'))
    if len(streams) != 1 or not math.isfinite(duration) or duration <= 0:
        raise ValueError('Recording has no positive-duration decodable video stream')
    stream = streams[0]
    if (stream.get('codec_name') != 'h264' or int(stream.get('width', 0)) <= 0
            or int(stream.get('height', 0)) <= 0 or int(stream.get('nb_read_frames', 0)) <= 0):
        raise ValueError('Recording must contain actual decodable H.264 frames')
    return {
        'path': path.name, 'bytes': path.stat().st_size, 'sha256': sha256(path),
        'duration_seconds': duration, 'decoded_frames': int(stream['nb_read_frames']),
        'codec': stream['codec_name'], 'width': stream['width'], 'height': stream['height'],
    }


def run_tour(session: TourSession) -> int:
    server = None
    thread = None
    recorder = VideoRecorder(session.device, session.output)
    ffprobe = None
    try:
        if sys.platform != 'darwin':
            raise ValueError('The visual tour requires macOS and an iOS Simulator')
        session.manifest['device'] = validate_device(session.device)
        flutter = shutil.which('flutter')
        ffprobe = shutil.which('ffprobe')
        if flutter is None or ffprobe is None:
            raise ValueError('Flutter and ffprobe (ffmpeg) must be installed and on PATH')
        fixtures = ('sample.mp4', 'ui-tour-manga.png')
        session.manifest['source_boundaries']['files'] = [
            {'path': f'tools/fixture_media/{name}',
             'bytes': (ROOT / 'tools/fixture_media' / name).stat().st_size,
             'sha256': sha256(ROOT / 'tools/fixture_media' / name)}
            for name in fixtures
        ]
        server = TourServer(session)
        base = f'http://127.0.0.1:{server.server_port}'
        session.manifest['source_boundaries']['base_url'] = base
        session.save()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        recorder.start()
        print(f'Capturing iOS visual tour to {session.output}', flush=True)
        with (session.output / 'flutter.log').open('wb') as log:
            code = run_integration(
                flutter, ROOT, session.device, 'integration_test/ios_visual_tour_test.dart',
                [f'TRIOMI_TOUR_BASE_URL={base}', f'TRIOMI_VIDEO_URL={base}/video/sample.mp4'],
                log, TOUR_TIMEOUT_SECONDS,
            )
        session.manifest['flutter_exit_code'] = code
        if code != 0:
            session.fail(f'Flutter visual tour failed with exit {code}; see flutter.log')
            print('\n'.join((session.output / 'flutter.log').read_text(
                encoding='utf-8', errors='replace').splitlines()[-120:]),
                file=sys.stderr, flush=True)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        session.fail(f'Tour execution failed: {error or type(error).__name__}')
    finally:
        try:
            recorder.stop()
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            session.fail(f'Recording finalization failed: {error}')
        if server is not None:
            if thread is not None and thread.is_alive():
                server.shutdown()
            server.server_close()
            if thread is not None:
                thread.join(timeout=5)
        try:
            session.validate_captures()
        except (OSError, ValueError) as error:
            session.fail(str(error))
        if ffprobe is not None and recorder.path.exists():
            try:
                session.manifest['recording'] = validate_video(recorder.path, ffprobe)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                session.fail(f'Recording validation failed: {error}')
        else:
            session.fail('No finalized recording is available')
        session.manifest['finished_at'] = timestamp()
        session.manifest['status'] = 'failed' if session.manifest['errors'] else 'passed'
        session.save()
    for error in session.manifest['errors']:
        print(error, file=sys.stderr)
    return 1 if session.manifest['errors'] else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Explicit already booted iOS Simulator UDID')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ios/visual-tour')
    args = parser.parse_args()
    session = TourSession(args.device, args.output)

    def interrupt(signum, frame):
        raise KeyboardInterrupt(f'Received signal {signum}')

    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        return run_tour(session)
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    raise SystemExit(main())
