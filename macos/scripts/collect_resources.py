"""Allowlisted, content-verified engine resources and redistribution notices."""

from __future__ import annotations

import hashlib
import importlib.metadata as metadata
import json
import runpy
import shutil
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

PROJECT = Path(__file__).resolve().parents[2]
PACKAGING = PROJECT / "macos/packaging"


def digest(path: Path, algorithm="sha3_256") -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def download(url: str, path: Path):
    if urlsplit(url).scheme != "https":
        raise ValueError("Build resources must use HTTPS")
    path.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(  # noqa: S310 — HTTPS validated above.
        url, headers={"User-Agent": "PDFTranslate-Build/0.2"}
    )
    # The only accepted URL scheme is checked above.
    with (
        urllib.request.urlopen(request, timeout=90) as response,  # noqa: S310
        path.open("wb") as stream,
    ):
        shutil.copyfileobj(response, stream)


def reviewed_license(distribution):
    """Resolve missing metadata only against reviewed, content-pinned notices."""
    declared = distribution.metadata.get(
        "License-Expression"
    ) or distribution.metadata.get("License")
    overrides = json.loads((PACKAGING / "license-overrides.json").read_text())
    review = next(
        (
            r
            for r in overrides
            if r["name"].lower() == distribution.metadata["Name"].lower()
        ),
        None,
    )
    if review:
        if distribution.version != review["version"]:
            raise RuntimeError(f"Re-review license after upgrading {review['name']}")
        for notice in review["files"]:
            path = Path(distribution.locate_file(notice["path"]))
            if not path.is_file() or digest(path, "sha256") != notice["sha256"]:
                raise RuntimeError(f"Reviewed license changed: {review['name']}")
        return review["license"], "reviewed-notice"
    if not declared or declared.strip().upper() in {"UNKNOWN", "UNLICENSED"}:
        raise RuntimeError(f"Missing license review: {distribution.metadata['Name']}")
    return declared, "package-metadata"


def collect_assets(stage: Path, seed: Path):
    package = Path(metadata.distribution("babeldoc").locate_file("babeldoc"))
    info = runpy.run_path(str(package / "assets/embedding_assets_metadata.py"))
    planned = []
    for group, key in (("fonts", "EMBEDDING_FONT_METADATA"), ("cmap", "CMAP_METADATA")):
        for name, details in info[key].items():
            planned.append(
                (
                    group,
                    name,
                    details["sha3_256"],
                    f"https://raw.githubusercontent.com/funstory-ai/BabelDOC-Assets/main/{group}/{name}",
                )
            )
    model = json.loads((PACKAGING / "licenses/DocLayout-provenance.json").read_text())
    planned.append(
        (
            "models",
            "doclayout_yolo_docstructbench_imgsz1024.onnx",
            info["DOCLAYOUT_YOLO_DOCSTRUCTBENCH_IMGSZ1024ONNX_SHA3_256"],
            model["source"],
        )
    )
    for name, hash_value in info["TIKTOKEN_CACHES"].items():
        planned.append(
            (
                "tiktoken",
                name,
                hash_value,
                "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken",
            )
        )
    destination = stage / "assets"
    destination.mkdir(parents=True, exist_ok=True)
    entries = []
    for group, name, expected, url in planned:
        relative = Path(group) / name
        target = destination / relative
        if not target.is_file() or digest(target) != expected:
            target.parent.mkdir(parents=True, exist_ok=True)
            cached = seed / relative
            if cached.is_file() and digest(cached) == expected:
                shutil.copyfile(cached, target)
            else:
                download(url, target)
            if digest(target) != expected:
                target.unlink(missing_ok=True)
                raise RuntimeError(f"Resource checksum failed: {relative}")
        if group == "models" and digest(target, "sha256") != model["sha256"]:
            raise RuntimeError(
                "Model no longer matches the reviewed publisher revision"
            )
        entries.append(
            {
                "path": str(relative),
                "sha3_256": expected,
                "size": target.stat().st_size,
                "source": url,
            }
        )
    # Remove no-longer-listed assets only within this dedicated generated directory.
    approved = {item["path"] for item in entries} | {"manifest.json"}
    for item in destination.rglob("*"):
        if item.is_file() and str(item.relative_to(destination)) not in approved:
            item.unlink()
    (destination / "manifest.json").write_text(
        json.dumps(
            {"babeldoc": metadata.version("babeldoc"), "files": entries}, indent=2
        )
        + "\n"
    )
    print(
        f"Bundled {len(entries)} verified assets, {sum(i['size'] for i in entries) / 1024**2:.1f} MiB",
        flush=True,
    )


def collect_licenses(stage: Path):
    from fontTools.ttLib import TTFont

    notices = stage / "licenses"
    if notices.exists():
        shutil.rmtree(notices)  # Regenerate notices; do not retain removed dependencies.
    notices.mkdir(parents=True, exist_ok=True)
    records = []
    for distribution in sorted(
        metadata.distributions(), key=lambda d: d.metadata["Name"].lower()
    ):
        name = distribution.metadata["Name"]
        destination = notices / "python-packages" / name
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "METADATA.txt").write_text(
            distribution.read_text("METADATA") or ""
        )
        copied = []
        for file in distribution.files or []:
            if any(
                token in file.name.lower()
                for token in ("license", "licence", "copying", "notice", "copyright")
            ):
                source = Path(distribution.locate_file(file))
                if source.is_file() and ".." not in file.parts:
                    output = destination / str(file)
                    output.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, output)
                    copied.append(str(output.relative_to(notices)))
        license_expression, evidence = reviewed_license(distribution)
        records.append(
            {
                "name": name,
                "version": distribution.version,
                "license": license_expression,
                "license_evidence": evidence,
                "license_classifiers": [
                    value
                    for value in distribution.metadata.get_all("Classifier", [])
                    if value.startswith("License ::")
                ],
                "homepage": distribution.metadata.get("Home-page"),
                "license_files": copied,
            }
        )
    # Embedded notices match the actual font binaries, including reserved names.
    for font in (stage / "assets/fonts").glob("*.ttf"):
        with TTFont(font) as data:
            lines = sorted(
                {
                    record.toUnicode()
                    for record in data["name"].names
                    if record.nameID in (0, 7, 8, 9, 13, 14)
                }
            )
        target = notices / "assets" / (font.name + ".txt")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("\n\n".join(lines) + "\n")
    pinned = PACKAGING / "licenses"
    if not (pinned / "sources.json").is_file():
        raise RuntimeError(
            "Fetch and review the pinned resource licenses before building."
        )
    for record in json.loads((pinned / "sources.json").read_text()):
        if digest(pinned / record["file"], "sha256") != record["sha256"]:
            raise RuntimeError(f"Vendored license checksum mismatch: {record['file']}")
    runtime_notices = pinned / "cpython-3.13.11-20251209"
    runtime_manifest = json.loads((runtime_notices / "manifest.json").read_text())
    for record in runtime_manifest["files"]:
        if digest(runtime_notices / record["file"], "sha256") != record["sha256"]:
            raise RuntimeError(f"Runtime license checksum mismatch: {record['file']}")
    shutil.copytree(pinned, notices / "resource-licenses", dirs_exist_ok=True)
    opencv = PROJECT / "macos/.build/opencv"
    opencv_manifest = json.loads((opencv / "manifest.json").read_text())
    for record in opencv_manifest["notices"]:
        if digest(opencv / "notices" / record["file"], "sha256") != record["sha256"]:
            raise RuntimeError(f"OpenCV license checksum mismatch: {record['file']}")
    shutil.copytree(
        opencv / "notices", notices / "opencv-source-notices", dirs_exist_ok=True
    )
    shutil.copyfile(opencv / "manifest.json", notices / "opencv-build.json")
    # install_only omits upstream's top-level licenses/ directory. The matching
    # full archive's notices and PYTHON.json above are required as well.
    python_root = Path(sys.base_prefix)
    python_notices = notices / "python-runtime"
    python_notices.mkdir(exist_ok=True)
    for source in python_root.rglob("*"):
        if source.is_file() and source.name.lower().startswith(
            ("license", "licence", "copying", "notice")
        ):
            relative = source.relative_to(python_root)
            output = python_notices / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, output)
    shutil.copyfile(PROJECT / "LICENSE", notices / "PDFMathTranslate-next-AGPL-3.0.txt")
    (notices / "dependencies.json").write_text(
        json.dumps(records, ensure_ascii=False, indent=2) + "\n"
    )
    (notices / "README.txt").write_text(
        "Rumi desktop beta — third-party notices\n\n"
        "The application and its modifications are offered under AGPL-3.0.\n"
        "The matching source archive is distributed alongside the application.\n"
        "Each dependency and asset retains its own copyright and license.\n"
        "Font notices are extracted from the exact bundled files; full licenses are included.\n"
        "Go Noto's build scripts use the Unlicense, but its generated fonts use OFL-1.1.\n"
        "dependencies.json also lists build tools, for reproducibility.\n"
    )
