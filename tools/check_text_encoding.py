"""Reject invalid UTF-8 and replacement characters in tracked project text."""

from pathlib import Path
import subprocess


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    paths = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=root
    ).decode("utf-8").split("\0")
    suffixes = {".md", ".dart", ".json", ".py", ".ps1", ".yaml", ".yml", ".xml", ".kt"}
    errors = []
    for name in paths:
        path = root / name
        if not name or not path.is_file() or path.suffix not in suffixes:
            continue
        try:
            text = path.read_bytes().decode("utf-8-sig")
        except UnicodeDecodeError as error:
            errors.append(f"{name}: invalid UTF-8 at byte {error.start}")
            continue
        if "\ufffd" in text:
            errors.append(f"{name}: contains Unicode replacement character")
    for error in errors:
        print(error)
    print(f"Encoding check: {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
