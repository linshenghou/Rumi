"""Record the actual frozen Mach-O inputs, including hidden wheel libraries.

This is evidence for a redistribution review, not an automatic license approval.
Run with the same interpreter and installed distributions that built the helper.
"""

from __future__ import annotations

import ast
import importlib.metadata as metadata
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

from collect_resources import digest


def owner_for_path(path, owners, python_root):
    path = path.resolve()
    if path in owners:
        return owners[path]
    if path.is_relative_to(python_root.resolve()):
        return {"name": "CPython", "version": sys.version.split()[0]}
    raise RuntimeError(f"Unowned native build input: {path.name}")


def create_inventory(build, engine):
    from build_app import is_macho

    owners = {}
    for distribution in metadata.distributions():
        owner = {"name": distribution.metadata["Name"], "version": distribution.version}
        for file in distribution.files or []:
            owners[Path(distribution.locate_file(file)).resolve()] = owner
    records = {}
    table = ast.literal_eval(
        (build / "pyinstaller-work/engine/COLLECT-00.toc").read_text()
    )[0]
    for destination, source, kind in table:
        if kind not in {"BINARY", "EXTENSION"}:
            continue
        relative = Path("_internal") / destination
        binary = engine / relative
        if not binary.is_file() or not is_macho(binary):
            raise RuntimeError(f"Missing native build output: {destination}")
        records[str(relative)] = {
            "path": str(relative),
            "owner": owner_for_path(Path(source), owners, Path(sys.base_prefix)),
            "input_sha256": digest(Path(source), "sha256"),
            "frozen_sha256": digest(binary, "sha256"),
            "dependencies": [
                line.strip().split(" (", 1)[0]
                for line in subprocess.check_output(
                    ["/usr/bin/otool", "-L", str(binary)], text=True
                ).splitlines()[1:]
            ],
        }
    executable = engine / "pdftranslate-engine"
    records[executable.name] = {
        "path": executable.name,
        "owner": {"name": "PyInstaller", "version": metadata.version("pyinstaller")},
        "frozen_sha256": digest(executable, "sha256"),
        "note": "PyInstaller bootloader and the Rumi Python archive",
    }
    # rglob includes .dylibs; symlink aliases are represented by their real file.
    observed = {p.resolve() for p in engine.rglob("*") if p.is_file() and is_macho(p)}
    recorded = {(engine / name).resolve() for name in records}
    if observed != recorded:
        raise RuntimeError("Native inventory does not cover every frozen Mach-O file")
    result = {
        "schema": 1,
        "scope": "Frozen helper before app signing; signing can change hashes. Package ownership does not resolve embedded-library license obligations.",
        "owners": dict(
            sorted(Counter(r["owner"]["name"] for r in records.values()).items())
        ),
        "files": [records[key] for key in sorted(records)],
    }
    (engine / "native-inventory.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


if __name__ == "__main__":
    from build_engine import BUILD
    from build_engine import ENGINE

    result = create_inventory(BUILD, ENGINE)
    print(json.dumps({"files": len(result["files"]), "owners": result["owners"]}))
