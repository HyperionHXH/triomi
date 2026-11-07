"""Exercise nullable desktop sort with the real pinned GraphQL schema and database."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java-home', required=True, type=Path)
    parser.add_argument('--server-jar', required=True, type=Path)
    parser.add_argument('--java', type=Path)
    parser.add_argument('--work-root', required=True, type=Path)
    parser.add_argument('--mangadex-jar', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.work_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='nullable-sort-', dir=args.work_root) as temporary:
        work = Path(temporary).resolve()
        classes = work / 'classes'
        classes.mkdir()
        server_root = work / 'server'
        (server_root / 'settings').mkdir(parents=True)
        (server_root / 'settings/migrations.xml').write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">\n'
            '<properties><entry key="version">3</entry></properties>\n', encoding='utf-8')
        (server_root / 'server.conf').write_text(
            'server.ip = "127.0.0.1"\nserver.authMode = "NONE"\n'
            'server.webUIEnabled = false\nserver.kcefEnabled = false\n'
            'server.initialOpenInBrowserEnabled = false\nserver.systemTrayEnabled = false\n'
            'server.extensionStores = []\nserver.globalUpdateInterval = 0.0\n'
            'server.backupInterval = 0\n', encoding='utf-8')
        subprocess.run([str(args.java_home / 'bin/javac.exe'), '--release', '21', '-encoding', 'UTF-8',
                        '-cp', str(args.server_jar.resolve()), '-d', str(classes),
                        str(root / 'tools/desktop/NullableFilterSearch.java'),
                        str(root / 'tools/tests/NullableFilterSearchTest.java')], check=True)
        command = [str(args.java or args.java_home / 'bin/java.exe'), '-Xmx512m', '-Djava.awt.headless=true',
                   f'-Dsuwayomi.tachidesk.config.server.rootDir={server_root.as_posix()}', '-cp',
                   str(classes) + ';' + str(args.server_jar.resolve()), 'triomi.desktop.NullableFilterSearchTest']
        if args.mangadex_jar:
            command.append(str(args.mangadex_jar.resolve()))
        subprocess.run(command, check=True, timeout=90)


if __name__ == '__main__':
    main()
