"""Install the checksum-pinned scanner into an ignored project directory."""

import hashlib
import platform
import tarfile
from pathlib import Path

from collect_resources import download

VERSION = "8.24.2"
HASHES = {
    ("Darwin", "arm64"): (
        "darwin_arm64",
        "90d13686937ac7429b97a3acbf1e1d0ce90d92ae2d0cf46a690bd8ae5230bea0",
    ),
    ("Linux", "x86_64"): (
        "linux_x64",
        "fa0500f6b7e41d28791ebc680f5dd9899cd42b58629218a5f041efa899151a8e",
    ),
}


def main():
    target = Path(__file__).resolve().parents[2] / "artifacts/tools"
    target.mkdir(parents=True, exist_ok=True)
    arch, checksum = HASHES[(platform.system(), platform.machine())]
    name = f"gitleaks_{VERSION}_{arch}.tar.gz"
    archive = target / name
    if (
        not archive.is_file()
        or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum
    ):
        download(
            f"https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/{name}",
            archive,
        )
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise RuntimeError("Scanner checksum mismatch")
    with tarfile.open(archive) as source:
        info = source.getmember("gitleaks")
        if not info.isfile():
            raise RuntimeError("Unexpected scanner archive member")
        with source.extractfile(info) as stream:
            (target / "gitleaks").write_bytes(stream.read())
    (target / "gitleaks").chmod(0o755)
    print(target / "gitleaks")


if __name__ == "__main__":
    main()
