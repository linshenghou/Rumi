"""Release guards must fail closed for identity, provenance and private inputs."""

import sys
import tarfile
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "macos/scripts"
sys.path.insert(0, str(SCRIPTS))
import audit_source  # noqa: E402
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
