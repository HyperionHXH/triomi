"""Run the real iOS video integration smoke against an isolated loopback fixture.

The server binds only the host loopback address; iOS Simulator shares that host.
No fixture video is bundled in the release IPA or added to Flutter assets.
"""
import argparse
from http.server import ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import threading

from dev_fixture_server import Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--suite', action='store_true',
                        help='Run all iOS JS, storage and player scenarios in one app')
    args = parser.parse_args()
    flutter = shutil.which('flutter')
    if flutter is None:
        raise SystemExit('Flutter must be on PATH')
    root = Path(__file__).resolve().parents[1]
    fixture = root / 'tools/fixture_media/sample.mp4'
    if not fixture.is_file():
        raise SystemExit(f'Missing existing video fixture: {fixture}')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f'http://127.0.0.1:{server.server_port}/video/sample.mp4'
        entrypoint = ('integration_test/ios_acceptance_test.dart' if args.suite
                      else 'integration_test/ios_video_live_test.dart')
        return subprocess.run([
            flutter, 'test', entrypoint,
            '-d', args.device, f'--dart-define=TRIOMI_VIDEO_URL={url}',
        ], cwd=root, check=False).returncode
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
