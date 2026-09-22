#!/usr/bin/env python3

import argparse
import pathlib
import re


def extract_release_notes(changelog: str, version: str) -> str:
    unreleased = re.compile(r"^##\s+\[?unreleased\]?(?:\s|$)", re.IGNORECASE)
    release = re.compile(rf"^##\s+\[?{re.escape(version)}\]?(?:\s|$)")

    lines = changelog.splitlines()
    unreleased_lines: list[str] = []
    release_lines: list[str] = []
    section: str | None = None

    for line in lines:
        if line.startswith("## "):
            if unreleased.match(line):
                section = "unreleased"
            elif release.match(line):
                section = "release"
            else:
                section = None
            continue
        if section == "unreleased":
            unreleased_lines.append(line)
        elif section == "release":
            release_lines.append(line)

    if any(line.strip() for line in unreleased_lines):
        raise ValueError(
            f"CHANGELOG.md still holds entries under Unreleased; promote them into {version}."
        )

    notes = "\n".join(release_lines).strip()
    if not notes:
        raise ValueError(f"CHANGELOG.md has no non-empty entry for {version}.")
    return f"{notes}\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("changelog", type=pathlib.Path)
    parser.add_argument("version")
    args = parser.parse_args()

    try:
        notes = extract_release_notes(
            args.changelog.read_text(encoding="utf-8"),
            args.version,
        )
    except ValueError as error:
        parser.error(str(error))
    print(notes, end="")


if __name__ == "__main__":
    main()
