#!/usr/bin/env python3
"""Compile the layered Icon Composer source for macOS and legacy systems."""

from __future__ import annotations

import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def compile_app_icon(
    document: Path,
    resources: Path,
    scratch: Path,
    minimum_system_version: str = "14.0",
) -> dict[str, str]:
    """Return the compiler's Info.plist entries after installing its resources.

    The .icon document is the source of both the native layered Assets.car and
    the ICNS fallback. Flattening the icon to PNG before compilation would lose
    the system's glass materials and appearance variants.
    """
    if document.suffix != ".icon" or not (document / "icon.json").is_file():
        raise SystemExit(f"Icon Composer document is missing: {document}")
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="icon-compile-", dir=scratch) as temporary:
        work = Path(temporary)
        compiled = work / "Resources"
        compiled.mkdir()
        partial_info = work / "icon-info.plist"
        subprocess.run(
            [
                "/usr/bin/xcrun",
                "actool",
                str(document.absolute()),
                "--compile",
                str(compiled.absolute()),
                "--output-format",
                "human-readable-text",
                "--notices",
                "--warnings",
                "--errors",
                "--app-icon",
                document.stem,
                "--output-partial-info-plist",
                str(partial_info.absolute()),
                "--platform",
                "macosx",
                "--minimum-deployment-target",
                minimum_system_version,
                "--target-device",
                "mac",
                "--standalone-icon-behavior",
                "all",
            ],
            check=True,
        )
        with partial_info.open("rb") as stream:
            info = plistlib.load(stream)
        expected = {
            "CFBundleIconName": document.stem,
            "CFBundleIconFile": document.stem,
        }
        if any(info.get(key) != value for key, value in expected.items()):
            raise SystemExit("The icon compiler did not declare the expected app icon.")
        artifacts = [compiled / "Assets.car", compiled / f"{document.stem}.icns"]
        for path in artifacts:
            if not path.is_file() or not path.stat().st_size:
                raise SystemExit(f"The icon compiler did not create {path.name}.")
        resources.mkdir(parents=True, exist_ok=True)
        for path in artifacts:
            shutil.copy2(path, resources / path.name)
        return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("document", type=Path)
    parser.add_argument("resources", type=Path)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--output-partial-info-plist", type=Path)
    args = parser.parse_args()
    info = compile_app_icon(args.document, args.resources, args.scratch)
    if args.output_partial_info_plist:
        args.output_partial_info_plist.parent.mkdir(parents=True, exist_ok=True)
        with args.output_partial_info_plist.open("wb") as stream:
            plistlib.dump(info, stream)


if __name__ == "__main__":
    main()
