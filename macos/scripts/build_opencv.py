"""Build the pinned, image-only OpenCV wheel used by the desktop helper.

The upstream macOS wheel pulls in video libraries Rumi does not use. This
explicit source-built override has a local version and separate provenance;
it is never represented as the unmodified PyPI wheel in requirements.lock.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import zipfile
from pathlib import Path

from collect_resources import digest
from collect_resources import download

PROJECT = Path(__file__).resolve().parents[2]
ROOT = PROJECT / "macos/.build/opencv"
PACKAGING = PROJECT / "macos/packaging"
VERSION = "4.13.0.92+rumi.1"
SOURCES = [
    {
        "name": "opencv-python",
        "version": "92",
        "file": "opencv-python-92.tar.gz",
        "url": "https://codeload.github.com/opencv/opencv-python/tar.gz/4ddfc013fd1f13d9b9e379dbebf2cdbeb052e7f8",
        "sha256": "ecc18f96559493a7968da6a0fa8fff2094a0d8a41f9cc03c8333139da0644171",
        "root": "opencv-python-4ddfc013fd1f13d9b9e379dbebf2cdbeb052e7f8",
    },
    {
        "name": "OpenCV",
        "version": "4.13.0-b4c5ec4",
        "file": "opencv-source.tar.gz",
        "url": "https://codeload.github.com/opencv/opencv/tar.gz/b4c5ec4042f097e2a5b386b9d413ec7333d0a184",
        "sha256": "4f2a381ce3377e6f22d0718fe7101e97a21968a21c81f0356f2787bb21024dc4",
        "root": "opencv-b4c5ec4042f097e2a5b386b9d413ec7333d0a184",
    },
]
FLAGS = [
    "-DBUILD_LIST=core,imgproc,imgcodecs,python3",
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
    "-DCMAKE_OSX_ARCHITECTURES=arm64",
    "-DWITH_FFMPEG=OFF",
    "-DWITH_GSTREAMER=OFF",
    "-DWITH_AVFOUNDATION=OFF",
    "-DWITH_1394=OFF",
    "-DWITH_V4L=OFF",
    "-DWITH_OPENCL=OFF",
    "-DWITH_OPENEXR=OFF",
    "-DWITH_WEBP=OFF",
    "-DWITH_TIFF=OFF",
    "-DWITH_OPENJPEG=OFF",
    "-DWITH_JASPER=OFF",
    "-DWITH_AVIF=OFF",
    "-DWITH_JPEGXL=OFF",
    "-DWITH_LAPACK=OFF",
    "-DWITH_IPP=OFF",
    "-DWITH_CAROTENE=OFF",
    "-DWITH_ITT=OFF",
    "-DBUILD_JPEG=ON",
    "-DBUILD_PNG=ON",
    "-DBUILD_ZLIB=ON",
    "-DBUILD_OPENEXR=OFF",
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local",
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
]


def run(command, **kwargs):
    subprocess.run([str(item) for item in command], check=True, **kwargs)


def patch_packaging(package):
    (package / "cv2/version.py").write_text(
        f'opencv_version = "{VERSION}"\ncontrib = False\nheadless = True\nrolling = False\nci_build = False\n'
    )
    path = package / "setup.py"
    text = path.read_text()
    # Upstream's optional typing generator assumes features2d/calib3d exist.
    # Do not ship stubs or G-API wrappers for modules deliberately not built.
    replacements = {
        '[ r"python/cv2/py.typed" ]': "[]",
        "    # Files in sourcetree outside package dir that should be copied to package.": '    rearrange_cmake_output_data.pop("cv2.gapi", None)\n'
        '    rearrange_cmake_output_data.pop("cv2.typing", None)\n\n'
        "    # Files in sourcetree outside package dir that should be copied to package.",
    }
    for before, after in replacements.items():
        if text.count(before) != 1:
            raise RuntimeError(
                "OpenCV packaging patch no longer matches reviewed source"
            )
        text = text.replace(before, after)
    path.write_text(text)


def build_wheel(python):
    uv, cmake = shutil.which("uv"), shutil.which("cmake")
    if not uv or not cmake:
        raise RuntimeError(
            "The engine build requires uv, CMake and Xcode command line tools"
        )
    ROOT.mkdir(parents=True, exist_ok=True)
    cache = PROJECT / "macos/.build/uv-cache"
    tools = ROOT / "venv"
    if not (tools / "bin/python").is_file():
        run([uv, "venv", "--python", python, tools, "--cache-dir", cache])
    run(
        [
            uv,
            "pip",
            "sync",
            "--python",
            tools / "bin/python",
            "--require-hashes",
            PACKAGING / "opencv-build.lock",
            "--cache-dir",
            cache,
        ]
    )
    toolchain = {
        "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[
            0
        ],
        "clang": subprocess.check_output(
            ["/usr/bin/clang", "--version"], text=True
        ).splitlines()[0],
        "python": subprocess.check_output(
            [str(python), "--version"], text=True
        ).strip(),
    }
    fingerprint = hashlib.sha256(
        Path(__file__).read_bytes()
        + (PACKAGING / "opencv-build.lock").read_bytes()
        + json.dumps(toolchain, sort_keys=True).encode()
    ).hexdigest()
    manifest_path = ROOT / "manifest.json"
    if manifest_path.is_file():
        record = json.loads(manifest_path.read_text())
        wheel = ROOT / "wheels" / record["wheel"]
        if (
            record["fingerprint"] == fingerprint
            and wheel.is_file()
            and digest(wheel, "sha256") == record["wheel_sha256"]
        ):
            return wheel
    work = ROOT / "work"
    if work.exists():
        shutil.rmtree(work)  # Dedicated generated source/build tree only.
    work.mkdir()
    for source in SOURCES:
        path = ROOT / source["file"]
        if not path.is_file() or digest(path, "sha256") != source["sha256"]:
            download(source["url"], path)
        if digest(path, "sha256") != source["sha256"]:
            raise RuntimeError(f"OpenCV source checksum mismatch: {path.name}")
        with tarfile.open(path) as archive:
            archive.extractall(work, filter="data")
    package = work / SOURCES[0]["root"]
    (package / "opencv").rmdir()  # Empty submodule placeholder in GitHub archive.
    (work / SOURCES[1]["root"]).rename(package / "opencv")
    patch_packaging(package)
    environment = dict(os.environ)
    environment.update(
        ENABLE_HEADLESS="1",
        CMAKE_GENERATOR="Unix Makefiles",
        CMAKE_BUILD_PARALLEL_LEVEL="8",
        MACOSX_DEPLOYMENT_TARGET="14.0",
        CMAKE_ARGS=" ".join(FLAGS),
        PIP_NO_CACHE_DIR="1",
    )
    wheels = ROOT / "wheels"
    wheels.mkdir(exist_ok=True)
    run(
        [
            tools / "bin/python",
            "-m",
            "pip",
            "wheel",
            ".",
            "--no-deps",
            "--no-build-isolation",
            "--wheel-dir",
            wheels,
        ],
        cwd=package,
        env=environment,
    )
    matches = list(wheels.glob(f"opencv_python_headless-{VERSION}-*arm64.whl"))
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one arm64 OpenCV wheel")
    wheel = matches[0]
    with zipfile.ZipFile(wheel) as archive:
        if any(
            ".dylibs/" in name or name.endswith(".dylib") for name in archive.namelist()
        ):
            raise RuntimeError(
                "Unexpected bundled dynamic library in image-only OpenCV"
            )
    notices = ROOT / "notices"
    notices.mkdir(exist_ok=True)
    notice_records = []
    for path in package.rglob("*"):
        relative = path.relative_to(package)
        if (
            path.is_file()
            and "_skbuild" not in relative.parts
            and (
                path.name.lower().startswith(
                    ("license", "licence", "copying", "copyright", "notice")
                )
                or path.name == "README.ijg"
            )
        ):
            destination = notices / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            notice_records.append(
                {"file": str(relative), "sha256": digest(path, "sha256")}
            )
    record = {
        "version": VERSION,
        "fingerprint": fingerprint,
        "wheel": wheel.name,
        "wheel_sha256": digest(wheel, "sha256"),
        "sources": SOURCES,
        "cmake_flags": FLAGS,
        "toolchain": toolchain,
        "notices": notice_records,
        "notice_scope": "Upstream source notices are retained, including optional components not built. Actual modules: core, imgproc, imgcodecs, python3. See native inventory for linked libraries.",
    }
    manifest_path.write_text(json.dumps(record, indent=2) + "\n")
    return wheel


def install_override(python, runtime_python):
    wheel = build_wheel(python)
    run(
        [
            shutil.which("uv"),
            "pip",
            "install",
            "--python",
            runtime_python,
            "--no-deps",
            "--reinstall",
            wheel,
            "--cache-dir",
            PROJECT / "macos/.build/uv-cache",
        ]
    )


if __name__ == "__main__":
    from build_engine import PYTHON
    from build_engine import VENV

    install_override(PYTHON, VENV / "bin/python")
