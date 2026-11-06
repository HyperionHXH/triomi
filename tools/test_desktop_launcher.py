"""Exercise the packaged Java launcher against the real pinned server in empty roots."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def verify_startup(java: Path, server: Path, launcher: Path, work: Path):
    with tempfile.TemporaryDirectory(prefix='desktop-startup-', dir=work) as temporary:
        root = Path(temporary)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        (root / 'settings').mkdir()
        # This root is empty; no original Java-registry preferences exist to migrate.
        (root / 'settings/migrations.xml').write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">\n'
            '<properties><entry key="version">3</entry></properties>\n', encoding='utf-8')
        (root / 'server.conf').write_text(
            f'server.ip = "127.0.0.1"\nserver.port = {port}\n'
            'server.authMode = "NONE"\nserver.webUIEnabled = false\n'
            'server.initialOpenInBrowserEnabled = false\nserver.systemTrayEnabled = false\n'
            'server.kcefEnabled = false\nserver.extensionStores = []\n'
            'server.globalUpdateInterval = 0.0\nserver.backupInterval = 0\n', encoding='utf-8')
        with (root / 'startup.log').open('wb') as log:
            process = subprocess.Popen([
                str(java), '-Xmx384m', '-Djava.awt.headless=true',
                f'-Dsuwayomi.tachidesk.config.server.rootDir={root.as_posix()}',
                '-cp', str(launcher) + ';' + str(server), 'triomi.desktop.DesktopLauncher',
            ], stdout=log, stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            try:
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise AssertionError(f'Runtime exited with {process.returncode}')
                    try:
                        with urllib.request.urlopen(
                                f'http://127.0.0.1:{port}/api/v1/settings/about', timeout=1) as response:
                            about = json.load(response)
                        assert about['version'] == 'v2.4.2366', about
                        with urllib.request.urlopen(
                                f'http://127.0.0.1:{port}/api/v1/source/list', timeout=2) as response:
                            sources = json.load(response)
                        assert any(source['id'] == '0' for source in sources)
                        break
                    except (OSError, urllib.error.URLError):
                        time.sleep(0.2)
                else:
                    raise AssertionError('Runtime failed to become ready within 60s')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        diagnostic = (root / 'startup.log').read_text(encoding='utf-8', errors='replace')
        assert 'ExceptionInInitializerError' not in diagnostic, diagnostic
        assert 'NoClassDefFoundError' not in diagnostic, diagnostic


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', type=Path, required=True)
    parser.add_argument('--server-jar', type=Path, required=True)
    parser.add_argument('--launcher-jar', type=Path, required=True)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--attempts', type=int, default=2)
    args = parser.parse_args()
    assert args.attempts > 0
    args.work_root.mkdir(parents=True, exist_ok=True)
    for attempt in range(args.attempts):
        verify_startup(args.java.resolve(), args.server_jar.resolve(),
                       args.launcher_jar.resolve(), args.work_root.resolve())
        print(f'Fresh desktop runtime startup {attempt + 1}/{args.attempts}: PASS')
