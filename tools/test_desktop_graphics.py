"""Run real desktop graphics pixel checks against the pinned server dependencies."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java-home', required=True, type=Path)
    parser.add_argument('--server-jar', required=True, type=Path)
    parser.add_argument('--java', type=Path, help='Run checks with the packaged private Java image')
    parser.add_argument('--work-root', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.work_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='graphics-', dir=args.work_root) as temporary:
        classes = Path(temporary)
        subprocess.run([str(args.java_home / 'bin/javac.exe'), '--release', '21', '-encoding', 'UTF-8',
                        '-cp', str(args.server_jar), '-d', str(classes),
                        *[str(path) for path in sorted((root / 'tools/desktop/android/graphics').glob('*.java'))],
                        str(root / 'tools/tests/DesktopGraphicsTest.java')], check=True)
        subprocess.run([str(args.java or args.java_home / 'bin/java.exe'), '-Djava.awt.headless=true', '-cp',
                        str(classes) + ';' + str(args.server_jar), 'DesktopGraphicsTest'], check=True, timeout=60)


if __name__ == '__main__':
    main()
