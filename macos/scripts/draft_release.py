"""Validate matching assets and create a DRAFT GitHub release; never publish it."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from audit_source import check_archive
from release_metadata import PROJECT
from release_metadata import load_release
from release_metadata import require_release_checkout


def validate_assets(directory: Path) -> list[Path]:
    release = load_release()
    commit = require_release_checkout()
    names = [
        release["dmg_name"],
        release["source_name"],
        "BUILD.json",
        "RELEASE_NOTES.md",
    ]
    checksums = directory / "SHA256SUMS.txt"
    expected = {}
    for line in checksums.read_text().splitlines():
        digest, name = line.split("  ", 1)
        if name in expected:
            raise RuntimeError("Duplicate checksum entry")
        expected[name] = digest
    if set(expected) != set(names):
        raise RuntimeError("Checksum manifest does not match required release assets")
    for name in names:
        with (directory / name).open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != expected[name]:
            raise RuntimeError(f"Release checksum mismatch: {name}")
    build = json.loads((directory / "BUILD.json").read_text())
    if (
        build["commit"] != commit
        or build["dirty"]
        or not build["release_checkout"]
        or build["product"] != release
    ):
        raise RuntimeError("Assets were not built from this clean, tagged release")
    check_archive(directory / release["source_name"])
    return [directory / name for name in [*names, "SHA256SUMS.txt"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    assets = validate_assets(args.directory)
    release = load_release()
    if args.dry_run:
        print("Validated draft assets: " + ", ".join(path.name for path in assets))
        return
    subprocess.run(
        [
            "gh",
            "release",
            "create",
            release["tag"],
            *map(str, assets),
            "--repo",
            f"{release['owner']}/{release['repository']}",
            "--verify-tag",
            "--draft",
            "--prerelease",
            "--title",
            f"Rumi {release['display_version']}",
            "--notes-file",
            str(args.directory / "RELEASE_NOTES.md"),
        ],
        check=True,
        cwd=PROJECT,
    )


if __name__ == "__main__":
    main()
