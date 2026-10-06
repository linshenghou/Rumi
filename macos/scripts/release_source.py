"""Create an allowlisted corresponding-source archive beside the internal DMG."""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import tarfile
from pathlib import Path

from audit_source import permitted
from build_engine import BUILD
from build_engine import PROJECT
from collect_resources import digest
from collect_resources import download
from release_metadata import git
from release_metadata import load_release


def collect_dependency_sources():
    destination = BUILD / "dependency-sources"
    destination.mkdir(parents=True, exist_ok=True)
    distributions = json.loads((BUILD / "stage/licenses/dependencies.json").read_text())
    entries = []
    for item in distributions:
        # Include corresponding upstream source for every copyleft runtime/tool.
        if not any(
            term in (item.get("license") or "").lower() for term in ("gpl", "mpl")
        ) and item["name"].lower() not in {
            "pymupdf",
            "babeldoc",
            "levenshtein",
            "pyinstaller",
        }:
            continue
        name, version = item["name"], item["version"]
        metadata_file = destination / f"{name}-{version}.pypi.json"
        if not metadata_file.exists():
            download(f"https://pypi.org/pypi/{name}/{version}/json", metadata_file)
        info = json.loads(metadata_file.read_text())
        sources = [f for f in info["urls"] if f["packagetype"] == "sdist"]
        if not sources:
            raise RuntimeError(
                f"Corresponding source archive missing: {name} {version}"
            )
        record = sources[0]
        path = destination / record["filename"]
        expected = record["digests"]["sha256"]
        if not path.exists() or digest(path, "sha256") != expected:
            download(record["url"], path)
        if digest(path, "sha256") != expected:
            raise RuntimeError(f"Corresponding source checksum mismatch: {name}")
        entries.append(
            {
                "name": name,
                "version": version,
                "file": path.name,
                "url": record["url"],
                "sha256": expected,
            }
        )
    # The PyMuPDF sdist fetches MuPDF separately; its linked AGPL library's
    # corresponding source must accompany the Python binding source too.
    mupdf = destination / "mupdf-1.25.2-source.tar.gz"
    mupdf_url = "https://mupdf.com/downloads/archive/mupdf-1.25.2-source.tar.gz"
    mupdf_sha256 = "36ccf6a5e691e188acf8db6e98d08bf05f27bb4ce30432dc15fc76d329a92d4d"
    if not mupdf.is_file() or digest(mupdf, "sha256") != mupdf_sha256:
        download(mupdf_url, mupdf)
    if digest(mupdf, "sha256") != mupdf_sha256:
        raise RuntimeError("MuPDF source checksum mismatch")
    if not tarfile.is_tarfile(mupdf):
        raise RuntimeError("Invalid MuPDF source distribution")
    entries.append(
        {
            "name": "MuPDF",
            "version": "1.25.2",
            "file": mupdf.name,
            "url": mupdf_url,
            "sha256": mupdf_sha256,
        }
    )
    (destination / "manifest.json").write_text(json.dumps(entries, indent=2) + "\n")
    return destination


def create_source_archive(output: Path, include_dependencies=True):
    dependencies = collect_dependency_sources() if include_dependencies else None
    output.parent.mkdir(parents=True, exist_ok=True)
    # Only version-controlled inputs, never arbitrary files placed inside source
    # directories. A release must first pass the clean/tagged checkout guard.
    allow = subprocess.check_output(
        ["git", "-C", str(PROJECT), "ls-files", "-z"], text=True
    ).split("\0")

    def source_only(info):
        path = Path(info.name)
        if "__pycache__" in path.parts or path.suffix in {
            ".pyc",
            ".db",
        }:
            return None
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info

    with tarfile.open(output, "w:gz", dereference=False) as archive:
        record = json.dumps(
            {"commit": git("rev-parse", "HEAD"), "product": load_release()}, indent=2
        ).encode()
        info = tarfile.TarInfo("Rumi-source/SOURCE_BUILD.json")
        info.size = len(record)
        archive.addfile(info, io.BytesIO(record))
        for relative in sorted(filter(None, allow)):
            if not permitted(relative):
                raise RuntimeError(f"Disallowed tracked source: {relative}")
            source = PROJECT / relative
            if source.is_file() and not source.is_symlink():
                archive.add(
                    source,
                    arcname=f"Rumi-source/{relative}",
                    filter=source_only,
                    recursive=False,
                )
        # Include the exact BabelDOC source after the isolated-cache adaptation.
        archive.add(
            BUILD / "stage/source/babeldoc",
            arcname="Rumi-source/third_party/babeldoc-0.6.2-desktop",
            filter=source_only,
        )
        archive.add(
            BUILD / "stage/assets/manifest.json",
            arcname="Rumi-source/asset-manifest.json",
        )
        archive.add(BUILD / "stage/licenses", arcname="Rumi-source/third_party/notices")
        archive.add(
            BUILD / "dist/pdftranslate-engine/build-manifest.json",
            arcname="Rumi-source/engine-build.json",
        )
        if dependencies:
            entries = json.loads((dependencies / "manifest.json").read_text())
            for name in ["manifest.json", *(entry["file"] for entry in entries)]:
                archive.add(
                    dependencies / name,
                    arcname=f"Rumi-source/third_party/upstream-source/{name}",
                )
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT / "artifacts/macos" / load_release()["source_name"],
    )
    options = parser.parse_args()
    print(
        collect_dependency_sources()
        if options.fetch_only
        else create_source_archive(options.output)
    )
