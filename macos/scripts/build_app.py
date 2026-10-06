#!/usr/bin/env python3
"""Build Rumi as a self-contained arm64 app; --development keeps local Python."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from build_engine import BUILD
from build_engine import ENGINE
from build_engine import PROJECT
from build_engine import source_fingerprint
from build_icon import compile_app_icon
from release_metadata import METADATA
from release_metadata import load_release
from release_metadata import provenance
from release_metadata import require_release_checkout


def run(command, **kwargs):
    return subprocess.run([str(part) for part in command], check=True, **kwargs)


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as file:
        return file.read(4) in {
            b"\xcf\xfa\xed\xfe",
            b"\xce\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf",
            b"\xca\xfe\xba\xbe",
            b"\xbe\xba\xfe\xca",
        }


def sign_internal(app: Path):
    # Sign nested Mach-O code explicitly, inside out. This internal build is
    # not Developer ID signed or notarized.
    for path in sorted(app.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if is_macho(path):
            run(
                ["/usr/bin/codesign", "--force", "--sign", "-", path],
                capture_output=True,
            )
    run(["/usr/bin/codesign", "--force", "--sign", "-", app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])


def assemble(args):
    release = load_release()
    record = provenance(release=args.release)
    icon_document = PROJECT / "macos/Resources/Branding/RumiIcon.icon"
    if not (icon_document / "icon.json").is_file():
        raise SystemExit(f"Rumi Icon Composer document is missing: {icon_document}")
    if not args.development:
        if args.reuse_engine:
            manifest = ENGINE / "build-manifest.json"
            if (
                not manifest.is_file()
                or json.loads(manifest.read_text())["source_fingerprint"]
                != source_fingerprint()
            ):
                raise SystemExit(
                    "Engine missing or stale. Run build_engine.py, or omit --reuse-engine."
                )
        else:
            run(
                [
                    sys.executable,
                    PROJECT / "macos/scripts/build_engine.py",
                    "--asset-cache",
                    args.asset_cache,
                ]
            )
    elif not args.python.is_file():
        raise SystemExit(f"Development Python not found: {args.python}")
    build = PROJECT / "macos/.build"
    command = [
        "/usr/bin/swift",
        "build",
        "--disable-sandbox",
        "--package-path",
        PROJECT / "macos",
        "--scratch-path",
        build,
        "--configuration",
        "release",
    ]
    run(command)
    binary_path = Path(
        subprocess.check_output(
            [str(p) for p in command] + ["--show-bin-path"], text=True
        ).strip()
    )
    output = args.output.absolute()
    staging = output.with_name(output.stem + ".staging.app")
    if staging.exists():
        shutil.rmtree(staging)
    contents = staging / "Contents"
    resources = contents / "Resources"
    resources.mkdir(parents=True)
    (contents / "MacOS").mkdir()
    shutil.copy2(binary_path / "PDFTranslate", contents / "MacOS/PDFTranslate")
    if args.development:
        (resources / "bootstrap.json").write_text(
            json.dumps(
                {
                    "projectPath": str(PROJECT),
                    "pythonPath": str(args.python.absolute()),
                },
                indent=2,
            )
            + "\n"
        )
    else:
        helper = contents / "Helpers/pdftranslate-engine"
        helper.parent.mkdir()
        shutil.copytree(ENGINE, helper, symlinks=True)
        # Helpers is a code location: placing fonts/headers there makes macOS
        # interpret ordinary data as unsigned nested code. Keep PyInstaller's
        # relative layout via a bundle-internal symlink to the resource tree.
        (helper / "_internal").rename(resources / "Engine")
        (helper / "_internal").symlink_to("../../Resources/Engine")
        (helper / "build-manifest.json").unlink()
        (helper / "native-inventory.json").rename(resources / "native-inventory.json")
        shutil.copytree(
            BUILD / "stage/licenses", resources / "ThirdPartyNotices", symlinks=True
        )
        shutil.copyfile(
            BUILD / "stage/assets/manifest.json", resources / "asset-manifest.json"
        )
        shutil.copyfile(ENGINE / "build-manifest.json", resources / "engine-build.json")
        (resources / "SOURCE.txt").write_text(
            "Rumi is offered under AGPL-3.0.\n"
            f"The matching {release['source_name']} is distributed alongside the DMG.\n"
            "It contains application sources, build scripts, locked dependencies, adapted BabelDOC source,\n"
            "and corresponding upstream source archives for copyleft dependencies.\n"
            f"Source and releases: {release['repository_url']}\n"
            "This community beta is ad-hoc signed, without Developer ID signing or Apple notarization.\n"
        )
    shutil.copyfile(PROJECT / "LICENSE", resources / "LICENSE")
    shutil.copyfile(METADATA, resources / "Release.json")
    (resources / "release-build.json").write_text(json.dumps(record, indent=2) + "\n")
    info = {
        "CFBundleIdentifier": release["bundle_id"],
        "CFBundleName": "Rumi",
        "CFBundleDisplayName": "Rumi",
        "CFBundleExecutable": "PDFTranslate",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": release["version"],
        "CFBundleVersion": release["build"],
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["en", "zh-Hans"],
        "LSMinimumSystemVersion": release["minimum_macos"],
        "LSArchitecturePriority": ["arm64"],
        "LSApplicationCategoryType": "public.app-category.productivity",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Rumi and PDFMathTranslate-next contributors. AGPL-3.0.",
        "CFBundleDocumentTypes": [
            {
                "CFBundleTypeName": "PDF document",
                "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": "Alternate",
                "LSItemContentTypes": ["com.adobe.pdf"],
            }
        ],
    }
    for localization in (PROJECT / "macos/Sources/PDFTranslate/Resources").glob(
        "*.lproj"
    ):
        shutil.copytree(localization, resources / localization.name)
    info.update(compile_app_icon(icon_document, resources, build))
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    sign_internal(staging)
    if output.exists():
        if not (output / "Contents/Info.plist").is_file():
            raise SystemExit(
                "Refusing to replace a path that is not an application bundle."
            )
        shutil.rmtree(output)
    staging.rename(output)
    return output


def package_dmg(app: Path, *, release_build=False):
    from release_source import create_source_archive

    release = load_release()
    if release_build:
        require_release_checkout()
    source = create_source_archive(app.parent / release["source_name"])
    disk_root = BUILD / "dmg-root"
    if disk_root.exists():
        shutil.rmtree(disk_root)
    disk_root.mkdir(parents=True)
    run(["/usr/bin/ditto", app, disk_root / app.name])
    (disk_root / "Applications").symlink_to("/Applications")
    (disk_root / "使用说明.txt").write_text(
        f"Rumi {release['display_version']} 社区测试版\n\n"
        "适用 Apple Silicon，macOS 14 或更新系统。拖到 Applications 安装。\n"
        "应用内置翻译引擎、字体与版面模型，无需安装 Python。\n"
        "填写自己的 DeepSeek 或 OpenAI 兼容 API 后开始翻译。\n\n"
        "免费开源；API 费用由你选择的服务商收取。\n"
        "此社区 Beta 未经过 Developer ID 签名和 Apple 公证。\n"
        "确认下载来源可信后，按 Apple 官方说明处理首次打开提示：\n"
        "https://support.apple.com/102445\n"
        f"对应源码：{release['source_name']}\n"
        f"下载与问题反馈：{release['repository_url']}\n"
    )
    shutil.copyfile(PROJECT / "docs/rumi/INSTALL.md", disk_root / "INSTALL.md")
    shutil.copyfile(PROJECT / "PRIVACY.md", disk_root / "PRIVACY.md")
    target = app.parent / release["dmg_name"]
    run(
        [
            "/usr/bin/hdiutil",
            "create",
            "-volname",
            "Rumi",
            "-srcfolder",
            disk_root,
            "-ov",
            "-format",
            "UDZO",
            target,
        ]
    )
    run(["/usr/bin/hdiutil", "verify", target])
    lines = []
    manifest = app.parent / "BUILD.json"
    shutil.copyfile(app / "Contents/Resources/release-build.json", manifest)
    shutil.copyfile(
        PROJECT / "docs/rumi/BETA_RELEASE.md", app.parent / "RELEASE_NOTES.md"
    )
    for path in (target, source, manifest, app.parent / "RELEASE_NOTES.md"):
        with path.open("rb") as stream:
            value = hashlib.file_digest(stream, "sha256").hexdigest()
        lines.append(f"{value}  {path.name}")
    (app.parent / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
    print(f"Community beta candidate: {target}\nMatching source: {source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=PROJECT / "artifacts/macos/Rumi.app"
    )
    parser.add_argument(
        "--development",
        action="store_true",
        help="Use local Python for development; not portable",
    )
    parser.add_argument("--python", type=Path, default=PROJECT / ".venv/bin/python")
    parser.add_argument(
        "--reuse-engine",
        action="store_true",
        help="Reuse a matching previously frozen helper",
    )
    parser.add_argument(
        "--asset-cache", type=Path, default=Path.home() / ".cache/babeldoc"
    )
    parser.add_argument(
        "--dmg",
        action="store_true",
        help="Generate community DMG, corresponding source, build record and checksums",
    )
    parser.add_argument(
        "--release", action="store_true", help="Require clean, matching tagged source"
    )
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("This beta build supports Apple Silicon macOS only.")
    if args.development and args.dmg:
        parser.error("Development apps cannot be packaged as standalone DMGs.")
    if args.development and args.release:
        parser.error("Release builds must use the standalone engine.")
    app = assemble(args)
    print(f"Built: {app}")
    if args.dmg:
        package_dmg(app, release_build=args.release)


if __name__ == "__main__":
    main()
