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
    output = root / 'build/ios/acceptance'
    output.mkdir(parents=True, exist_ok=True)
    log = output / 'flutter.log'
    result = 1
    try:
        url = f'http://127.0.0.1:{server.server_port}/video/sample.mp4'
        entrypoint = ('integration_test/ios_acceptance_test.dart' if args.suite
                      else 'integration_test/ios_video_live_test.dart')
        with log.open('w', encoding='utf-8') as stream:
            try:
                result = subprocess.run([
                    flutter, 'test', '--no-pub', '--verbose', entrypoint,
                    '-d', args.device, f'--dart-define=TRIOMI_VIDEO_URL={url}',
                ], cwd=root, stdout=stream, stderr=subprocess.STDOUT,
                    timeout=900, check=False).returncode
            except subprocess.TimeoutExpired:
                print('iOS acceptance exceeded its 15-minute host deadline.',
                      flush=True)
        if result:
            subprocess.run([
                'xcrun', 'simctl', 'io', args.device, 'screenshot',
                str(output / 'failure.png'),
            ], timeout=30, check=False)
            print(log.read_text(encoding='utf-8', errors='replace')[-30000:],
                  flush=True)
        return result
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
