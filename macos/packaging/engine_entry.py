"""Minimal entry point for the redistributable background translation worker."""

if __name__ == "__main__":
    import multiprocessing

    # Must precede argparse, application imports, and any heavy native imports.
    multiprocessing.freeze_support()

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path


def checksum(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha3_256").hexdigest()


def prepare_assets() -> None:
    bundled = Path(sys._MEIPASS) / "assets"
    manifest = json.loads((bundled / "manifest.json").read_text())
    target = Path(os.environ["PDFTRANSLATE_CACHE_DIR"]) / "babeldoc"
    for item in manifest["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("invalid resource manifest")
        source = bundled / relative
        destination = target / relative
        # Always verify to recover corrupted caches and fail closed on damaged bundles.
        if destination.is_file() and checksum(destination) == item["sha3_256"]:
            continue
        if not source.is_file() or checksum(source) != item["sha3_256"]:
            raise ValueError("damaged resource")
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + f".{os.getpid()}.tmp")
        try:
            shutil.copyfile(source, temporary)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)


def main() -> int:
    try:
        prepare_assets()
        from pdf2zh_next.desktop_bridge import main as bridge_main
    except Exception:
        # Build diagnostics are limited to bootstrap, before reading any request
        # or API key. Translation exceptions are handled only by the safe bridge.
        if os.environ.get("PDFTRANSLATE_BOOT_DIAGNOSTICS") == "1":
            import traceback

            traceback.print_exc(file=sys.stderr)
        print(
            json.dumps(
                {
                    "type": "error",
                    "code": "engine",
                    "message": "翻译引擎资源缺失或损坏，请重新安装应用。",
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
        return 1
    return bridge_main()


if __name__ == "__main__":
    sys.exit(main())
