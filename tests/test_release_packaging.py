"""Release guards must fail closed for identity, provenance and private inputs."""

import hashlib
import json
import sys
import tarfile
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "macos/scripts"
sys.path.insert(0, str(SCRIPTS))
import audit_source  # noqa: E402
import draft_release  # noqa: E402
import release_metadata  # noqa: E402


def test_release_identity_and_artifacts_use_one_version():
    info = release_metadata.load_release()
    assert info["bundle_id"] != "org.pdfmathtranslate.next.desktop"
    assert info["bundle_id"] == f"io.github.{info['owner'].lower()}.rumi"
    assert info["label"] in info["source_name"] and info["label"] in info["dmg_name"]
    assert info["tag"] == "v" + info["label"]


@pytest.mark.parametrize(
    "name",
    [
        "artifacts/leak.txt",
        "macos/.build/config.json",
        ".env.local",
        "paper.pdf",
        "private.glossary.csv",
        "private.key",
        "../config",
        "/tmp/config",
    ],
)
def test_private_and_generated_paths_are_rejected(name):
    assert not audit_source.permitted(name)


def test_tracked_upstream_pdf_fixture_is_allowed():
    assert audit_source.permitted("test/file/translate.cli.plain.text.pdf")


def test_release_guard_rejects_dirty_tree(monkeypatch):
    monkeypatch.setattr(release_metadata, "git", lambda *args: " M README.md")
    with pytest.raises(RuntimeError, match="clean checkout"):
        release_metadata.require_release_checkout()


def test_release_guard_rejects_wrong_tag(monkeypatch):
    monkeypatch.setattr(
        release_metadata,
        "git",
        lambda *args: (
            "" if args[0] == "status" else "head" if args[-1] == "HEAD" else "other"
        ),
    )
    with pytest.raises(RuntimeError, match="Release tag"):
        release_metadata.require_release_checkout()


def test_archive_links_cannot_escape_source_root(tmp_path):
    path = tmp_path / "source.tar.gz"
    with tarfile.open(path, "w:gz") as archive:
        info = tarfile.TarInfo("Rumi-source/escape")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
        archive.addfile(info)
    with pytest.raises(RuntimeError, match="Unsafe source archive"):
        audit_source.check_archive(path)


def test_extracted_complete_source_builds_without_git(tmp_path, monkeypatch):
    (tmp_path / "SOURCE_BUILD.json").write_text(json.dumps({"commit": "source-commit"}))
    lock = tmp_path / "macos/packaging/requirements.lock"
    lock.parent.mkdir(parents=True)
    lock.write_text("fixture")
    monkeypatch.setattr(release_metadata, "PROJECT", tmp_path)
    monkeypatch.setattr(
        release_metadata.subprocess,
        "check_output",
        lambda *args, **kwargs: "test-toolchain",
    )
    result = release_metadata.provenance()
    assert result["commit"] == "source-commit"
    assert result["dirty"] and not result["release_checkout"]


@pytest.fixture
def draft_assets(tmp_path, monkeypatch):
    info = release_metadata.load_release()
    monkeypatch.setattr(
        draft_release, "require_release_checkout", lambda: "release-commit"
    )
    (tmp_path / info["dmg_name"]).write_bytes(b"synthetic fixture only")
    with tarfile.open(tmp_path / info["source_name"], "w:gz"):
        pass
    (tmp_path / "RELEASE_NOTES.md").write_text("Fixture notes")
    (tmp_path / "BUILD.json").write_text(
        json.dumps(
            {
                "commit": "release-commit",
                "dirty": False,
                "release_checkout": True,
                "product": info,
            }
        )
    )
    return tmp_path, info


def write_checksums(directory):
    files = sorted(p for p in directory.iterdir() if p.name != "SHA256SUMS.txt")
    (directory / "SHA256SUMS.txt").write_text(
        "".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in files
        )
    )


def test_draft_rejects_tampered_dmg(draft_assets):
    directory, info = draft_assets
    write_checksums(directory)
    (directory / info["dmg_name"]).write_bytes(b"changed")
    with pytest.raises(RuntimeError, match="checksum mismatch"):
        draft_release.validate_assets(directory)


def test_draft_rejects_dirty_build_even_with_valid_checksums(draft_assets):
    directory, _ = draft_assets
    build = json.loads((directory / "BUILD.json").read_text())
    build["dirty"] = True
    (directory / "BUILD.json").write_text(json.dumps(build))
    write_checksums(directory)
    with pytest.raises(RuntimeError, match="clean, tagged"):
        draft_release.validate_assets(directory)
