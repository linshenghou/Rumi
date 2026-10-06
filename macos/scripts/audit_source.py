"""Scan candidate source, Git history and optional source archive without printing secrets."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from pathlib import PurePosixPath

PROJECT = Path(__file__).resolve().parents[2]


def permitted(name: str) -> bool:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        return False
    if set(path.parts) & {
        "artifacts",
        ".build",
        ".venv",
        "__pycache__",
        ".git",
        ".claude",
        ".codex",
        ".agents",
        "pdf2zh_files",
    }:
        return False
    if path.name.startswith(".env") and path.name != ".env.example":
        return False
    if path.suffix.lower() in {
        ".key",
        ".pem",
        ".dmg",
        ".pyc",
        ".db",
        ".sqlite",
        ".docx",
    }:
        return False
    if path.name.endswith(".glossary.csv"):
        return False
    # Only the three inherited, synthetic upstream PDF fixtures belong in Git.
    if path.suffix.lower() == ".pdf" and name not in {
        "test/file/translate.cli.font.unknown.pdf",
        "test/file/translate.cli.plain.text.pdf",
        "test/file/translate.cli.text.with.figure.pdf",
    }:
        return False
    return True


def candidate_files() -> list[str]:
    output = subprocess.check_output(
        [
            "git",
            "-C",
            str(PROJECT),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
        text=True,
    )
    return sorted(
        {name for name in output.split("\0") if name and (PROJECT / name).exists()}
    )


def check_archive(path: Path):
    with tarfile.open(path) as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if (
                name.is_absolute()
                or ".." in name.parts
                or member.issym()
                or member.islnk()
            ):
                raise RuntimeError(f"Unsafe source archive member: {member.name}")
            if not name.parts or name.parts[0] != "Rumi-source":
                raise RuntimeError("Unexpected source archive root")
            relative = str(PurePosixPath(*name.parts[1:]))
            if not permitted(relative):
                raise RuntimeError(f"Disallowed source archive member: {member.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scanner", type=Path, default=PROJECT / "artifacts/tools/gitleaks"
    )
    parser.add_argument("--history", action="store_true")
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--reports", type=Path, default=PROJECT / "artifacts/audit")
    args = parser.parse_args()
    args.reports.mkdir(parents=True, exist_ok=True)

    def scan(mode, source, name, *extra):
        subprocess.run(
            [
                str(args.scanner.absolute()),
                mode,
                str(source),
                "--redact=100",
                "--no-banner",
                "--report-format=json",
                f"--report-path={args.reports / (name + '.json')}",
                *extra,
            ],
            check=True,
            cwd=PROJECT,
        )

    files = candidate_files()
    forbidden = [
        name for name in files if not permitted(name) or (PROJECT / name).is_symlink()
    ]
    if forbidden:
        raise RuntimeError("Disallowed publish inputs: " + ", ".join(forbidden))
    with tempfile.TemporaryDirectory(prefix="rumi-source-audit-") as directory:
        root = Path(directory)
        for name in files:
            source = PROJECT / name
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        scan("dir", root, "working-tree")
    if args.history:
        scan("git", PROJECT, "history", "--log-opts=--all")
    if args.archive:
        check_archive(args.archive)
        scan("dir", args.archive.absolute(), "source-archive", "--max-archive-depth=3")
    print(f"Source safety passed: {len(files)} candidate files")


if __name__ == "__main__":
    main()
