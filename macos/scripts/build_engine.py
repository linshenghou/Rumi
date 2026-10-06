#!/usr/bin/env python3
"""Build the pinned arm64 desktop helper without the developer's Python/config."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
PACKAGING = PROJECT / "macos/packaging"
BUILD = PROJECT / "macos/.build/standalone"
PYTHON_VERSION = "3.13.11"
MANAGED = PROJECT / "macos/.build/python"
PYTHON = MANAGED / f"cpython-{PYTHON_VERSION}-macos-aarch64-none/bin/python3.13"
VENV = BUILD / "venv"
ENGINE = BUILD / "dist/pdftranslate-engine"


def source_fingerprint():
    checksum = hashlib.sha256()
    paths = (
        list((PROJECT / "pdf2zh_next").rglob("*.py"))
        + [p for p in PACKAGING.rglob("*") if "__pycache__" not in p.parts]
        + [
            PROJECT / "macos/scripts" / name
            for name in (
                "build_engine.py",
                "collect_resources.py",
                "native_inventory.py",
                "build_opencv.py",
            )
        ]
        + [PROJECT / "LICENSE", PROJECT / "pyproject.toml"]
    )
    for path in sorted(paths):
        if path.is_file():
            checksum.update(str(path.relative_to(PROJECT)).encode())
            checksum.update(path.read_bytes())
    return checksum.hexdigest()


def run(command, **kwargs):
    subprocess.run([str(item) for item in command], check=True, **kwargs)


def prepare_python():
    from build_opencv import install_override

    uv = shutil.which("uv")
    if not uv:
        raise SystemExit(
            "Install uv to build the independent engine: https://docs.astral.sh/uv/"
        )
    cache = PROJECT / "macos/.build/uv-cache"
    # The same Python patch version may be rebuilt with different native
    # dependencies. Pin the archive build and digest as well as 3.13.11.
    run(
        [
            uv,
            "python",
            "install",
            PYTHON_VERSION,
            "--reinstall",
            "--python-downloads-json-url",
            (PACKAGING / "python-downloads.json").as_uri(),
            "--install-dir",
            MANAGED,
            "--cache-dir",
            cache,
        ]
    )
    if not (VENV / "bin/python").exists():
        run([uv, "venv", "--python", PYTHON, VENV, "--cache-dir", cache])
    run(
        [
            uv,
            "pip",
            "sync",
            "--python",
            VENV / "bin/python",
            "--require-hashes",
            PACKAGING / "requirements.lock",
            "--cache-dir",
            cache,
        ]
    )
    install_override(PYTHON, VENV / "bin/python")


def patch(path: Path, old: str, new: str):
    contents = path.read_text()
    if contents.count(old) != 1:
        raise RuntimeError(f"The reviewed cache patch no longer matches: {path.name}")
    path.write_text(contents.replace(old, new))


def stage_sources():
    import importlib.metadata

    stage = BUILD / "stage"
    source = stage / "source"
    source.mkdir(parents=True, exist_ok=True)
    # Only package sources; caches, user configuration and PDFs are never inputs.
    for name, original in (
        ("pdf2zh_next", PROJECT / "pdf2zh_next"),
        (
            "babeldoc",
            Path(importlib.metadata.distribution("babeldoc").locate_file("babeldoc")),
        ),
    ):
        destination = source / name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(
            original, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
        )
    patch(
        source / "babeldoc/const.py",
        'CACHE_FOLDER = Path.home() / ".cache" / "babeldoc"',
        'CACHE_FOLDER = Path(os.environ["PDFTRANSLATE_CACHE_DIR"]) / "babeldoc"',
    )
    patch(
        source / "pdf2zh_next/const.py",
        'DEFAULT_CONFIG_DIR = Path("~/.config/pdf2zh").expanduser()',
        'import os\nDEFAULT_CONFIG_DIR = Path(os.environ["PDFTRANSLATE_CONFIG_DIR"])',
    )
    patch(
        source / "pdf2zh_next/translator/cache.py",
        'cache_folder = Path.home() / ".cache" / "pdf2zh_next"',
        'import os\n    cache_folder = Path(os.environ["PDFTRANSLATE_CACHE_DIR"]) / "translation"',
    )
    return stage


def build_inside_environment(asset_cache: Path, skip_freeze: bool):
    from collect_resources import collect_assets
    from collect_resources import collect_licenses

    input_fingerprint = source_fingerprint()
    stage = stage_sources()
    collect_assets(stage, asset_cache)
    collect_licenses(stage)
    if skip_freeze:
        return
    environment = dict(os.environ)
    environment["PDFTRANSLATE_ENGINE_STAGE"] = str(stage)
    environment["PYINSTALLER_CONFIG_DIR"] = str(BUILD / "pyinstaller-cache")
    environment["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    # Imports during module analysis must not touch personal caches either.
    environment["PDFTRANSLATE_CACHE_DIR"] = str(BUILD / "analysis-cache")
    environment["PDFTRANSLATE_CONFIG_DIR"] = str(BUILD / "analysis-cache/configuration")
    # Staged adapters must win over the checkout and installed BabelDOC package.
    environment["PYTHONPATH"] = str(stage / "source")
    run(
        [
            sys.executable,
            "-m",
            "PyInstaller",
            "--noconfirm",
            "--clean",
            "--distpath",
            BUILD / "dist",
            "--workpath",
            BUILD / "pyinstaller-work",
            PACKAGING / "engine.spec",
        ],
        env=environment,
        cwd=BUILD,
    )
    from native_inventory import create_inventory

    create_inventory(BUILD, ENGINE)
    (ENGINE / "build-manifest.json").write_text(
        json.dumps(
            {
                "python": PYTHON_VERSION,
                "python_distribution": json.loads(
                    (PACKAGING / "python-downloads.json").read_text()
                ),
                "architecture": "arm64",
                "minimum_macos": "14.0",
                "source_fingerprint": input_fingerprint,
                "requirements_sha256": hashlib.sha256(
                    (PACKAGING / "requirements.lock").read_bytes()
                ).hexdigest(),
                "source_built_overrides": [
                    json.loads(
                        (PROJECT / "macos/.build/opencv/manifest.json").read_text()
                    )
                ],
            },
            indent=2,
        )
        + "\n"
    )
    print(f"Standalone helper: {ENGINE / 'pdftranslate-engine'}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--asset-cache",
        type=Path,
        default=Path.home() / ".cache/babeldoc",
        help="Optional hash-verified build seed; only named model/font assets are read",
    )
    parser.add_argument("--inside-venv", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--skip-freeze", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("The first desktop beta must be built on Apple Silicon macOS.")
    if args.inside_venv:
        build_inside_environment(args.asset_cache, args.skip_freeze)
    else:
        prepare_python()
        command = [
            VENV / "bin/python",
            __file__,
            "--inside-venv",
            "--asset-cache",
            args.asset_cache,
        ]
        if args.skip_freeze:
            command.append("--skip-freeze")
        run(command)


if __name__ == "__main__":
    main()
