#!/usr/bin/env python3
"""Verify frozen helper relocatability, native dependency isolation and assets."""

import argparse
import json
import re
import shutil
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from build_app import is_macho


def inspect_binary(path):
    architecture = subprocess.check_output(
        ["/usr/bin/lipo", "-archs", str(path)], text=True
    ).strip()
    if architecture != "arm64":
        raise RuntimeError(f"Unexpected architecture ({architecture}): {path.name}")
    output = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("/") and not dependency.startswith(
            ("/System/Library/", "/usr/lib/")
        ):
            raise RuntimeError(f"External native dependency: {path.name}: {dependency}")
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
    for block in commands.split("Load command ")[1:]:
        field = (
            "minos"
            if "cmd LC_BUILD_VERSION\n" in block
            else "version"
            if "cmd LC_VERSION_MIN_MACOSX\n" in block
            else None
        )
        if field:
            match = re.search(r"^\s*" + field + r"\s+([0-9.]+)", block, re.MULTILINE)
            if match and tuple(int(n) for n in match.group(1).split(".")[:2]) > (14, 0):
                raise RuntimeError(
                    f"Requires newer than macOS 14: {path.name}: {match.group(1)}"
                )
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", str(path)],
        check=True,
        capture_output=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path, help="The onedir helper directory")
    parser.add_argument(
        "--startup-timeout",
        type=float,
        default=300,
        help="Fresh ad-hoc native libraries can require lengthy macOS signature checks",
    )
    args = parser.parse_args()
    original = args.engine.resolve()
    binaries = [path for path in original.rglob("*") if is_macho(path)]
    with ThreadPoolExecutor(max_workers=6) as pool:
        tasks = [pool.submit(inspect_binary, path) for path in binaries]
        failures = []
        for task in tasks:
            try:
                task.result()
            except Exception as error:
                failures.append(str(error))
        if failures:
            raise RuntimeError("\n".join(failures))
    with tempfile.TemporaryDirectory(
        prefix="pdftranslate-portability-", dir="/private/tmp"
    ) as directory:
        root = Path(directory)
        relocated = root / "中文 space" / "pdftranslate-engine"
        shutil.copytree(original, relocated, symlinks=True)
        for link in relocated.rglob("*"):
            if link.is_symlink() and not link.resolve().is_relative_to(relocated):
                raise RuntimeError(f"External symlink: {link.name}")
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "PDFTRANSLATE_CACHE_DIR": str(root / "fresh-cache"),
        }
        executable = relocated / "pdftranslate-engine"
        started = time.monotonic()
        result = subprocess.run(
            [str(executable), "--check"],
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=args.startup_timeout,
        )
        cold_start_seconds = time.monotonic() - started
        if result.returncode:
            raise RuntimeError(
                f"Relocated engine failed: {result.stdout} {result.stderr}"
            )
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert any(event["type"] == "ready" for event in events)
        assert not result.stderr.strip(), "Unexpected engine startup diagnostics"
        # Deliberately damage one cache asset and prove repair uses the bundle.
        metadata = json.loads(
            (relocated / "_internal/assets/manifest.json").read_text()
        )
        sample = metadata["files"][0]
        cached = root / "fresh-cache/babeldoc" / sample["path"]
        cached.write_bytes(b"damaged test cache")
        repair = subprocess.run(
            [str(executable), "--check"],
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=args.startup_timeout,
        )
        assert repair.returncode == 0 and cached.stat().st_size == sample["size"]
    print(
        json.dumps(
            {
                "result": "passed",
                "native_binaries": len(binaries),
                "architecture": "arm64",
                "relocation": "Chinese + spaces",
                "cache_repair": True,
                "cold_start_seconds": round(cold_start_seconds, 2),
            }
        )
    )


if __name__ == "__main__":
    main()
