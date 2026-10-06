"""Shared product identity and release provenance (no credentials or host paths)."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
METADATA = PROJECT / "macos/Sources/PDFTranslate/Resources/Release.json"


def load_release(path: Path = METADATA) -> dict:
    value = json.loads(path.read_text())
    if not re.fullmatch(r"\d+\.\d+\.\d+", value["version"]):
        raise ValueError("Expected a numeric three-part product version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", value["owner"]):
        raise ValueError("Invalid GitHub owner")
    if value["repository"] != "Rumi" or value["channel"] != "beta":
        raise ValueError("This pipeline builds Rumi community betas only")
    if (
        not str(value["build"]).isdigit()
        or int(value["build"]) < 1
        or value["beta"] < 1
    ):
        raise ValueError("Build and beta numbers must be positive")
    value["label"] = f"{value['version']}-beta.{value['beta']}"
    value["tag"] = "v" + value["label"]
    value["display_version"] = f"{value['version']} Beta {value['beta']}"
    value["bundle_id"] = f"io.github.{value['owner'].lower()}.rumi"
    value["repository_url"] = (
        f"https://github.com/{value['owner']}/{value['repository']}"
    )
    value["source_name"] = f"Rumi-{value['label']}-source.tar.gz"
    value["dmg_name"] = f"Rumi-{value['label']}-arm64-community.dmg"
    return value


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(PROJECT), *args], text=True
    ).strip()


def require_release_checkout() -> str:
    release = load_release()
    if git("status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError(
            "Release builds require a clean checkout, including untracked source"
        )
    commit = git("rev-parse", "HEAD")
    if git("rev-parse", f"{release['tag']}^{{commit}}") != commit:
        raise RuntimeError("Release tag must point to HEAD and match Release.json")
    return commit


def provenance(*, release: bool = False) -> dict:
    if release:
        commit = require_release_checkout()
        dirty = False
    elif (PROJECT / ".git").exists():
        commit = git("rev-parse", "HEAD")
        dirty = bool(git("status", "--porcelain", "--untracked-files=all"))
    else:
        # The complete corresponding-source attachment must build without Git.
        source_record = PROJECT / "SOURCE_BUILD.json"
        commit = (
            json.loads(source_record.read_text())["commit"]
            if source_record.is_file()
            else None
        )
        dirty = True  # An extracted/modified tree has no Git integrity assertion.

    def version(*command):
        return subprocess.check_output(command, text=True).strip()

    return {
        "product": load_release(),
        "commit": commit,
        "dirty": dirty,
        "release_checkout": release,
        "signing": "ad-hoc; no Developer ID signature; not notarized",
        "swift": version("swift", "--version"),
        "xcode": version("xcodebuild", "-version"),
        "macos": version("sw_vers", "-productVersion"),
        "uv": version("uv", "--version"),
        "requirements_sha256": hashlib.sha256(
            (PROJECT / "macos/packaging/requirements.lock").read_bytes()
        ).hexdigest(),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--field")
    parser.add_argument("--check-release", action="store_true")
    args = parser.parse_args()
    if args.check_release:
        require_release_checkout()
    value = load_release()
    print(value[args.field] if args.field else json.dumps(value, indent=2))
