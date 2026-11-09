#!/usr/bin/env python3
"""Show or change the release version in Config/Version.xcconfig.

    scripts/version.py              # print "2.0.0 (179)"
    scripts/version.py bump patch   # 2.0.0 -> 2.0.1, build +1
    scripts/version.py bump minor   # 2.0.1 -> 2.1.0, build +1
    scripts/version.py bump major   # 2.1.0 -> 3.0.0, build +1
    scripts/version.py set 2.3.4    # explicit version, build +1

Every release advances the build number, so it only ever grows.
"""
from __future__ import annotations

import pathlib
import re
import sys

PATH = pathlib.Path(__file__).resolve().parent.parent / "Config" / "Version.xcconfig"


def read() -> tuple[str, int]:
    text = PATH.read_text()
    version = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)", text, re.M).group(1)
    build = int(re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*(\d+)", text, re.M).group(1))
    return version, build


def write(version: str, build: int) -> None:
    text = PATH.read_text()
    text = re.sub(r"^MARKETING_VERSION\s*=.*$", f"MARKETING_VERSION = {version}", text, flags=re.M)
    text = re.sub(r"^CURRENT_PROJECT_VERSION\s*=.*$", f"CURRENT_PROJECT_VERSION = {build}", text, flags=re.M)
    PATH.write_text(text)


def main(argv: list[str]) -> int:
    version, build = read()
    if not argv:
        print(f"{version} ({build})")
        return 0
    if argv[0] == "bump" and len(argv) == 2 and argv[1] in ("patch", "minor", "major"):
        major, minor, patch = (int(part) for part in version.split("."))
        if argv[1] == "major":
            major, minor, patch = major + 1, 0, 0
        elif argv[1] == "minor":
            minor, patch = minor + 1, 0
        else:
            patch += 1
        version = f"{major}.{minor}.{patch}"
    elif argv[0] == "set" and len(argv) == 2 and re.fullmatch(r"\d+\.\d+\.\d+", argv[1]):
        version = argv[1]
    else:
        print(__doc__)
        return 2
    write(version, build + 1)
    print(f"{version} ({build + 1})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
