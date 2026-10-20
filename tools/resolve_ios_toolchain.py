"""Resolve iOS CI's exact Flutter SDK from the existing build/release pins.

No separate iOS version pin or fallback SDK is maintained. The installed SDK is
also checked against pubspec's Dart caret constraint before dependencies resolve.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def repository_toolchain() -> tuple[str, tuple[int, int, int]]:
    versions = []
    for name in ('build.yml', 'release.yml'):
        text = (ROOT / '.github' / 'workflows' / name).read_text(encoding='utf-8')
        environment = re.search(r'^env:\s*\n((?:[ \t]+[^\n]*\n|\n)*)', text, re.MULTILINE)
        match = re.search(
            r"^  FLUTTER_VERSION: ['\"]?(\d+\.\d+\.\d+)['\"]?\s*$",
            environment.group(1) if environment else '', re.MULTILINE,
        )
        if not match:
            raise ValueError(f'{name} must declare an exact env.FLUTTER_VERSION')
        versions.append(match.group(1))
    if len(set(versions)) != 1:
        raise ValueError('Existing build and release Flutter SDK pins disagree')
    pubspec = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    match = re.search(r"^  sdk: ['\"]?\^(\d+)\.(\d+)\.(\d+)['\"]?\s*$", pubspec, re.MULTILINE)
    if not match:
        raise ValueError('Expected the repository Dart SDK caret constraint in pubspec.yaml')
    return versions[0], tuple(map(int, match.groups()))


def verify_installed(flutter_version: str, minimum: tuple[int, int, int]) -> None:
    machine = json.loads(subprocess.check_output(
        ['flutter', '--version', '--machine'], text=True,
    ))
    if machine['frameworkVersion'] != flutter_version or machine.get('channel') != 'stable':
        raise ValueError('Installed Flutter does not match the repository exact stable SDK pin')
    dart = re.match(r'^(\d+)\.(\d+)\.(\d+)(.*)$', machine['dartSdkVersion'])
    if not dart:
        raise ValueError('Cannot read the installed Dart SDK version')
    actual = tuple(map(int, dart.groups()[:3]))
    # Dart caret ranges for pre-1.0 versions advance the first nonzero component.
    upper = ((minimum[0] + 1, 0, 0) if minimum[0] else
             (0, minimum[1] + 1, 0) if minimum[1] else (0, 0, minimum[2] + 1))
    if not minimum <= actual < upper or '-' in dart.group(4):
        raise ValueError(f'Installed Dart {machine["dartSdkVersion"]} does not satisfy ^{".".join(map(str, minimum))}')
    print(f'Confirmed Flutter {flutter_version} / Dart {machine["dartSdkVersion"]}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--verify-installed', action='store_true')
    args = parser.parse_args()
    version, minimum = repository_toolchain()
    if args.verify_installed:
        verify_installed(version, minimum)
    else:
        print(version)
    if args.github_output:
        with args.github_output.open('a', encoding='utf-8') as stream:
            stream.write(f'flutter-version={version}\n')


if __name__ == '__main__':
    main()
